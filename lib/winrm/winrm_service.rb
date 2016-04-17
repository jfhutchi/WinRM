# encoding: UTF-8
#
# Copyright 2010 Dan Wanek <dan.wanek@gmail.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'nori'
require 'rexml/document'
require 'securerandom'
require_relative 'command_executor'
require_relative 'command_output_decoder'
require_relative 'helpers/powershell_script'
require_relative 'WSMV/create_shell_message'

module WinRM
  # This is the main class that does the SOAP request/response logic. There are a few helper
  # classes, but pretty much everything comes through here first.
  class WinRMWebService
    DEFAULT_TIMEOUT = 60
    DEFAULT_MAX_ENV_SIZE = 153600
    DEFAULT_LOCALE = 'en-US'

    attr_reader :endpoint, :timeout, :retry_limit, :retry_delay, :output_decoder

    attr_accessor :logger

    # @param [String,URI] endpoint the WinRM webservice endpoint
    # @param [Symbol] transport either :kerberos(default)/:ssl/:plaintext
    # @param [Hash] opts Misc opts for the various transports.
    #   @see WinRM::HTTP::HttpTransport
    #   @see WinRM::HTTP::HttpGSSAPI
    #   @see WinRM::HTTP::HttpNegotiate
    #   @see WinRM::HTTP::HttpSSL
    def initialize(endpoint, transport = :kerberos, opts = {})
      @session_id = SecureRandom.uuid.to_s.upcase
      @endpoint = endpoint
      @operation_timeout = DEFAULT_TIMEOUT
      @max_env_sz = DEFAULT_MAX_ENV_SIZE
      @locale = DEFAULT_LOCALE
      @output_decoder = CommandOutputDecoder.new
      setup_logger
      configure_retries(opts)
      begin
        @xfer = send "init_#{transport}_transport", opts.merge({endpoint: endpoint})
      rescue NoMethodError => e
        raise "Invalid transport '#{transport}' specified, expected: negotiate, kerberos, plaintext, ssl."
      end
    end

    def init_negotiate_transport(opts)
      HTTP::HttpNegotiate.new(opts[:endpoint], opts[:user], opts[:pass], opts)
    end

    def init_kerberos_transport(opts)
      require 'gssapi'
      require 'gssapi/extensions'
      HTTP::HttpGSSAPI.new(opts[:endpoint], opts[:realm], opts[:service], opts[:keytab], opts)
    end

    def init_plaintext_transport(opts)
      HTTP::HttpPlaintext.new(opts[:endpoint], opts[:user], opts[:pass], opts)
    end

    def init_ssl_transport(opts)
      if opts[:basic_auth_only]
        HTTP::BasicAuthSSL.new(opts[:endpoint], opts[:user], opts[:pass], opts)
      else
        HTTP::HttpNegotiate.new(opts[:endpoint], opts[:user], opts[:pass], opts)
      end
    end

    # Operation timeout.
    # 
    # Unless specified the client receive timeout will be 10s + the operation
    # timeout.
    #
    # @see http://msdn.microsoft.com/en-us/library/ee916629(v=PROT.13).aspx
    #
    # @param [Fixnum] The number of seconds to set the WinRM operation timeout
    # @param [Fixnum] The number of seconds to set the Ruby receive timeout
    # @return [String] The ISO 8601 formatted operation timeout
    def set_timeout(op_timeout_sec, receive_timeout_sec=nil)
      @operation_timeout = op_timeout_sec
      @xfer.receive_timeout = receive_timeout_sec || op_timeout_sec + 10
      Iso8601Duration.sec_to_dur(@operation_timeout)
    end
    alias :op_timeout :set_timeout

    # The operation timeout
    def timeout
      @operation_timeout
    end

    # Max envelope size
    # @see http://msdn.microsoft.com/en-us/library/ee916127(v=PROT.13).aspx
    # @param [Fixnum] byte_sz the max size in bytes to allow for the response
    def max_env_size(byte_sz)
      @max_env_sz = byte_sz
    end

    # Set the locale
    # @see http://msdn.microsoft.com/en-us/library/gg567404(v=PROT.13).aspx
    # @param [String] locale the locale to set for future messages
    def locale(locale)
      @locale = locale
    end

    # Create a Shell on the destination host
    # @param [Hash<optional>] shell_opts additional shell options you can pass
    # @option shell_opts [String] :i_stream Which input stream to open.  Leave this alone unless you know what you're doing (default: stdin)
    # @option shell_opts [String] :o_stream Which output stream to open.  Leave this alone unless you know what you're doing (default: stdout stderr)
    # @option shell_opts [String] :working_directory The directory to create the shell in
    # @option shell_opts [String] :codepage The shell code page, defaults to 65001 (UTF-8)
    # @option shell_opts [String] :noprofile The WINRS_NOPROFILE setting, defaults to 'FALSE'
    # @option shell_opts [Fixnum] :idle_timeout The shell IdleTimeOut in seconds
    # @option shell_opts [Hash] :env_vars environment variables to set for the shell. For instance;
    #   :env_vars => {:myvar1 => 'val1', :myvar2 => 'var2'}
    # @return [String] The ShellId from the SOAP response. This is our open shell instance on the remote machine.
    def open_shell(shell_opts = {}, &block)
      shell_id = SecureRandom.uuid.to_s.upcase
      logger.debug("[WinRM] opening remote shell on #{@endpoint}")
      msg = WSMV::CreateShellMessage.new(session_opts, shell_opts)
      resp_doc = send_message(msg.build)
      # CMD shell returns a new shell_id
      shell_id = REXML::XPath.first(resp_doc, "//*[@Name='ShellId']").text
      logger.debug("[WinRM] remote shell #{shell_id} is open on #{@endpoint}")

      #keep_alive(shell_id)

      if block_given?
        begin
          yield shell_id
        ensure
          close_shell(shell_id)
        end
      else
        shell_id
      end
    end

    def keep_alive(shell_id)
      h_opts = { "#{NS_WSMAN_DMTF}:OptionSet" => { "#{NS_WSMAN_DMTF}:Option" => "TRUE",
        :attributes! => {"#{NS_WSMAN_DMTF}:Option" => {'Name' => 'WSMAN_CMDSHELL_OPTION_KEEPALIVE'}}}}
      body = { "#{NS_WIN_SHELL}:DesiredStream" => 'stdout' }
      builder = Builder::XmlMarkup.new
      builder.instruct!(:xml, :encoding => 'UTF-8')
      builder.tag! :env, :Envelope, namespaces do |env|
        env.tag!(:env, :Header) { |h| h << Gyoku.xml(merge_headers(header,resource_uri_cmd,action_receive,h_opts,selector_shell_id(shell_id))) }
        env.tag! :env, :Body do |env_body|
          env_body.tag!("#{NS_WIN_SHELL}:Receive") { |cl| cl << Gyoku.xml(body) }
        end
      end

      resp_doc = send_message(builder.target!)
    end

    # Run a command on a machine with an open shell
    # @param [String] shell_id The shell id on the remote machine.  See #open_shell
    # @param [String] command The command to run on the remote machine
    # @param [Array<String>] arguments An array of arguments for this command
    # @return [String] The CommandId from the SOAP response.  This is the ID we need to query in order to get output.
    def run_command(shell_id, command, arguments = [], cmd_opts = {}, &block)
      command_id = SecureRandom.uuid.to_s.upcase
      consolemode = cmd_opts.has_key?(:console_mode_stdin) ? cmd_opts[:console_mode_stdin] : 'TRUE'
      skipcmd     = cmd_opts.has_key?(:skip_cmd_shell) ? cmd_opts[:skip_cmd_shell] : 'FALSE'

      h_opts = { "#{NS_WSMAN_DMTF}:OptionSet" => {
        "#{NS_WSMAN_DMTF}:Option" => [consolemode, skipcmd],
        :attributes! => {"#{NS_WSMAN_DMTF}:Option" => {'Name' => ['WINRS_CONSOLEMODE_STDIN','WINRS_SKIP_CMD_SHELL']}}}
      }

      argument_xml = %{<Obj RefId="0"><MS><Obj N="PowerShell" RefId="1"><MS><Obj N="Cmds" RefId="2"><TN RefId="0"><T>System.Collections.Generic.List`1[[System.Management.Automation.PSObject, System.Management.Automation, Version=3.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35]]</T><T>System.Object</T></TN><LST><Obj RefId="3"><MS><S N="Cmd">Invoke-expression</S><B N="IsScript">false</B><Nil N="UseLocalScope" /><Obj N="MergeMyResult" RefId="4"><TN RefId="1"><T>System.Management.Automation.Runspaces.PipelineResultTypes</T><T>System.Enum</T><T>System.ValueType</T><T>System.Object</T></TN><ToString>None</ToString><I32>0</I32></Obj><Obj N="MergeToResult" RefId="5"><TNRef RefId="1" /><ToString>None</ToString><I32>0</I32></Obj><Obj N="MergePreviousResults" RefId="6"><TNRef RefId="1" /><ToString>None</ToString><I32>0</I32></Obj><Obj N="MergeError" RefId="7"><TNRef RefId="1" /><ToString>None</ToString><I32>0</I32></Obj><Obj N="MergeWarning" RefId="8"><TNRef RefId="1" /><ToString>None</ToString><I32>0</I32></Obj><Obj N="MergeVerbose" RefId="9"><TNRef RefId="1" /><ToString>None</ToString><I32>0</I32></Obj><Obj N="MergeDebug" RefId="10"><TNRef RefId="1" /><ToString>None</ToString><I32>0</I32></Obj><Obj N="Args" RefId="11"><TNRef RefId="0" /><LST><Obj RefId="12"><MS><S N="N">-Command</S><Nil N="V" /></MS></Obj><Obj RefId="13"><MS><Nil N="N" /><S N="V">#{command}</S></MS></Obj></LST></Obj></MS></Obj><Obj RefId="14"><MS><S N="Cmd">Out-string</S><B N="IsScript">false</B><Nil N="UseLocalScope" /><Obj N="MergeMyResult" RefId="15"><TNRef RefId="1" /><ToString>None</ToString><I32>0</I32></Obj><Obj N="MergeToResult" RefId="16"><TNRef RefId="1" /><ToString>None</ToString><I32>0</I32></Obj><Obj N="MergePreviousResults" RefId="17"><TNRef RefId="1" /><ToString>None</ToString><I32>0</I32></Obj><Obj N="MergeError" RefId="18"><TNRef RefId="1" /><ToString>None</ToString><I32>0</I32></Obj><Obj N="MergeWarning" RefId="19"><TNRef RefId="1" /><ToString>None</ToString><I32>0</I32></Obj><Obj N="MergeVerbose" RefId="20"><TNRef RefId="1" /><ToString>None</ToString><I32>0</I32></Obj><Obj N="MergeDebug" RefId="21"><TNRef RefId="1" /><ToString>None</ToString><I32>0</I32></Obj><Obj N="Args" RefId="22"><TNRef RefId="0" /><LST /></Obj></MS></Obj></LST></Obj><B N="IsNested">false</B><Nil N="History" /><B N="RedirectShellErrorOutputPipe">true</B></MS></Obj><B N="NoInput">true</B><Obj N="ApartmentState" RefId="23"><TN RefId="2"><T>System.Threading.ApartmentState</T><T>System.Enum</T><T>System.ValueType</T><T>System.Object</T></TN><ToString>Unknown</ToString><I32>2</I32></Obj><Obj N="RemoteStreamOptions" RefId="24"><TN RefId="3"><T>System.Management.Automation.RemoteStreamOptions</T><T>System.Enum</T><T>System.ValueType</T><T>System.Object</T></TN><ToString>0</ToString><I32>0</I32></Obj><B N="AddToHistory">true</B><Obj N="HostInfo" RefId="25"><MS><B N="_isHostNull">true</B><B N="_isHostUINull">true</B><B N="_isHostRawUINull">true</B><B N="_useRunspaceHost">true</B></MS></Obj><B N="IsNested">false</B></MS></Obj>}
      
      b64_arguments = encode_bytes(psrp_message(shell_id, command_id, '00021006', argument_xml))

      body = { "#{NS_WIN_SHELL}:Command" => "Invoke-Expression", "#{NS_WIN_SHELL}:Arguments" => b64_arguments }

      builder = Builder::XmlMarkup.new
      builder.instruct!(:xml, :encoding => 'UTF-8')
      builder.tag! :env, :Envelope, namespaces do |env|
        env.tag!(:env, :Header) { |h| h << Gyoku.xml(merge_headers(header,resource_uri_cmd,action_command,selector_shell_id(shell_id))) }
        env.tag!(:env, :Body) do |env_body|
          env_body.tag!("#{NS_WIN_SHELL}:CommandLine", {"CommandId" => command_id}) { |cl| cl << Gyoku.xml(body) }
        end
      end

      # Grab the command element and unescape any single quotes - issue 69
      xml = builder.target!

      resp_doc = send_message(xml)
      command_id = REXML::XPath.first(resp_doc, "//#{NS_WIN_SHELL}:CommandId").text

      if block_given?
        begin
          yield command_id
        ensure
          cleanup_command(shell_id, command_id)
        end
      else
        command_id
      end
    end

    def write_stdin(shell_id, command_id, stdin)
      # Signal the Command references to terminate (close stdout/stderr)
      body = {
        "#{NS_WIN_SHELL}:Send" => {
          "#{NS_WIN_SHELL}:Stream" => {
            "@Name" => 'stdin',
            "@CommandId" => command_id,
            :content! => Base64.encode64(stdin)
          }
        }
      }
      builder = Builder::XmlMarkup.new
      builder.instruct!(:xml, :encoding => 'UTF-8')
      builder.tag! :env, :Envelope, namespaces do |env|
        env.tag!(:env, :Header) { |h| h << Gyoku.xml(merge_headers(header,resource_uri_cmd,action_send,selector_shell_id(shell_id))) }
        env.tag!(:env, :Body) do |env_body|
          env_body << Gyoku.xml(body)
        end
      end
      resp = send_message(builder.target!)
      true
    end

    # Get the Output of the given shell and command
    # @param [String] shell_id The shell id on the remote machine.  See #open_shell
    # @param [String] command_id The command id on the remote machine.  See #run_command
    # @return [Hash] Returns a Hash with a key :exitcode and :data.  Data is an Array of Hashes where the cooresponding key
    #   is either :stdout or :stderr.  The reason it is in an Array so so we can get the output in the order it ocurrs on
    #   the console.
    def get_command_output(shell_id, command_id, &block)
      body = { "#{NS_WIN_SHELL}:DesiredStream" => 'stdout',
        :attributes! => {"#{NS_WIN_SHELL}:DesiredStream" => {'CommandId' => command_id}}}

      builder = Builder::XmlMarkup.new
      builder.instruct!(:xml, :encoding => 'UTF-8')
      builder.tag! :env, :Envelope, namespaces do |env|
        env.tag!(:env, :Header) { |h| h << Gyoku.xml(merge_headers(header,resource_uri_cmd,action_receive,selector_shell_id(shell_id))) }
        env.tag!(:env, :Body) do |env_body|
          env_body.tag!("#{NS_WIN_SHELL}:Receive") { |cl| cl << Gyoku.xml(body) }
        end
      end

      resp_doc = nil
      request_msg = builder.target!
      done_elems = []
      output = Output.new

      while done_elems.empty?
        resp_doc = send_get_output_message(request_msg)

        REXML::XPath.match(resp_doc, "//#{NS_WIN_SHELL}:Stream").each do |n|
          next if n.text.nil? || n.text.empty?

          decoded_text = output_decoder.decode(n.text)
          stream = { n.attributes['Name'].to_sym => decoded_text }
          output[:data] << stream
          yield stream[:stdout], stream[:stderr] if block_given?
        end

        # We may need to get additional output if the stream has not finished.
        # The CommandState will change from Running to Done like so:
        # @example
        #   from...
        #   <rsp:CommandState CommandId="..." State="http://schemas.microsoft.com/wbem/wsman/1/windows/shell/CommandState/Running"/>
        #   to...
        #   <rsp:CommandState CommandId="..." State="http://schemas.microsoft.com/wbem/wsman/1/windows/shell/CommandState/Done">
        #     <rsp:ExitCode>0</rsp:ExitCode>
        #   </rsp:CommandState>
        done_elems = REXML::XPath.match(resp_doc, "//*[@State='http://schemas.microsoft.com/wbem/wsman/1/windows/shell/CommandState/Done']")
      end

      output[:exitcode] = REXML::XPath.first(resp_doc, "//#{NS_WIN_SHELL}:ExitCode").text.to_i
      output
    end

    # Clean-up after a command.
    # @see #run_command
    # @param [String] shell_id The shell id on the remote machine.  See #open_shell
    # @param [String] command_id The command id on the remote machine.  See #run_command
    # @return [true] This should have more error checking but it just returns true for now.
    def cleanup_command(shell_id, command_id)
      # Signal the Command references to terminate (close stdout/stderr)
      body = { "#{NS_WIN_SHELL}:Code" => 'http://schemas.microsoft.com/wbem/wsman/1/windows/shell/signal/terminate' }
      builder = Builder::XmlMarkup.new
      builder.instruct!(:xml, :encoding => 'UTF-8')
      builder.tag! :env, :Envelope, namespaces do |env|
        env.tag!(:env, :Header) { |h| h << Gyoku.xml(merge_headers(header,resource_uri_cmd,action_signal,selector_shell_id(shell_id))) }
        env.tag!(:env, :Body) do |env_body|
          env_body.tag!("#{NS_WIN_SHELL}:Signal", {'CommandId' => command_id}) { |cl| cl << Gyoku.xml(body) }
        end
      end
      resp = send_message(builder.target!)
      true
    end

    # Close the shell
    # @param [String] shell_id The shell id on the remote machine.  See #open_shell
    # @return [true] This should have more error checking but it just returns true for now.
    def close_shell(shell_id)
      logger.debug("[WinRM] closing remote shell #{shell_id} on #{@endpoint}")
      builder = Builder::XmlMarkup.new
      builder.instruct!(:xml, :encoding => 'UTF-8')

      builder.tag!('env:Envelope', namespaces) do |env|
        env.tag!('env:Header') { |h| h << Gyoku.xml(merge_headers(header,resource_uri_cmd,action_delete,selector_shell_id(shell_id))) }
        env.tag!('env:Body')
      end

      resp = send_message(builder.target!)
      logger.debug("[WinRM] remote shell #{shell_id} closed")
      true
    end

    # DEPRECATED: Use WinRM::CommandExecutor#run_cmd instead
    # Run a CMD command
    # @param [String] command The command to run on the remote system
    # @param [Array <String>] arguments arguments to the command
    # @param [String] an existing and open shell id to reuse
    # @return [Hash] :stdout and :stderr
    def run_cmd(command, arguments = [], &block)
      logger.warn("WinRM::WinRMWebService#run_cmd is deprecated. Use WinRM::CommandExecutor#run_cmd instead")
      create_executor do |executor|
        executor.run_cmd(command, arguments, &block)
      end
    end
    alias :cmd :run_cmd

    # DEPRECATED: Use WinRM::CommandExecutor#run_powershell_script instead
    # Run a Powershell script that resides on the local box.
    # @param [IO,String] script_file an IO reference for reading the Powershell script or the actual file contents
    # @param [String] an existing and open shell id to reuse
    # @return [Hash] :stdout and :stderr
    def run_powershell_script(script_file, &block)
      logger.warn("WinRM::WinRMWebService#run_powershell_script is deprecated. Use WinRM::CommandExecutor#run_powershell_script instead")
      create_executor do |executor|
        executor.run_powershell_script(script_file, &block)
      end
    end
    alias :powershell :run_powershell_script

    # Creates a CommandExecutor initialized with this WinRMWebService
    # If called with a block, create_executor yields an executor and
    # ensures that the executor is closed after the block completes.
    # The CommandExecutor is simply returned if no block is given.
    # @yieldparam [CommandExecutor] a CommandExecutor instance
    # @return [CommandExecutor] a CommandExecutor instance
    def create_executor(&block)
      executor = CommandExecutor.new(self)
      executor.open

      if block_given?
        begin
          yield executor
        ensure
          executor.close
        end
      else
        executor
      end
    end

    # Run a WQL Query
    # @see http://msdn.microsoft.com/en-us/library/aa394606(VS.85).aspx
    # @param [String] wql The WQL query
    # @return [Hash] Returns a Hash that contain the key/value pairs returned from the query.
    def run_wql(wql)

      body = { "#{NS_WSMAN_DMTF}:OptimizeEnumeration" => nil,
        "#{NS_WSMAN_DMTF}:MaxElements" => '32000',
        "#{NS_WSMAN_DMTF}:Filter" => wql,
        "#{NS_WSMAN_MSFT}:SessionId" => "uuid:#{@session_id}",
        :attributes! => { "#{NS_WSMAN_DMTF}:Filter" => {'Dialect' => 'http://schemas.microsoft.com/wbem/wsman/1/WQL'}}
      }

      builder = Builder::XmlMarkup.new
      builder.instruct!(:xml, :encoding => 'UTF-8')
      builder.tag! :env, :Envelope, namespaces do |env|
        env.tag!(:env, :Header) { |h| h << Gyoku.xml(merge_headers(header,resource_uri_wmi,action_enumerate)) }
        env.tag!(:env, :Body) do |env_body|
          env_body.tag!("#{NS_ENUM}:Enumerate") { |en| en << Gyoku.xml(body) }
        end
      end

      resp = send_message(builder.target!)
      parser = Nori.new(:parser => :rexml, :advanced_typecasting => false, :convert_tags_to => lambda { |tag| tag.snakecase.to_sym }, :strip_namespaces => true)
      hresp = parser.parse(resp.to_s)[:envelope][:body]
      
      # Normalize items so the type always has an array even if it's just a single item.
      items = {}
      if hresp[:enumerate_response][:items]
        hresp[:enumerate_response][:items].each_pair do |k,v|
          if v.is_a?(Array)
            items[k] = v
          else
            items[k] = [v]
          end
        end
      end
      items
    end
    alias :wql :run_wql

    def toggle_nori_type_casting(to)
      logger.warn('toggle_nori_type_casting is deprecated and has no effect, ' +
        'please remove calls to it')
    end

    private

    def session_opts
      {
        endpoint: @endpoint,
        max_envelope_size: @max_env_sz,
        session_id: @session_id,
        operation_timeout: @operation_timeout,
        locale: @locale
      }
    end

    def setup_logger
      @logger = Logging.logger[self]
      @logger.level = :warn
      @logger.add_appenders(Logging.appenders.stdout)
    end

    def configure_retries(opts)
      @retry_delay = opts[:retry_delay] || 10
      @retry_limit = opts[:retry_limit] || 3
    end

    def namespaces
      {
        'xmlns:xsd' => 'http://www.w3.org/2001/XMLSchema',
        'xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance',
        'xmlns:env' => 'http://www.w3.org/2003/05/soap-envelope',
        'xmlns:a' => 'http://schemas.xmlsoap.org/ws/2004/08/addressing',
        'xmlns:b' => 'http://schemas.dmtf.org/wbem/wsman/1/cimbinding.xsd',
        'xmlns:n' => 'http://schemas.xmlsoap.org/ws/2004/09/enumeration',
        'xmlns:x' => 'http://schemas.xmlsoap.org/ws/2004/09/transfer',
        'xmlns:w' => 'http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd',
        'xmlns:p' => 'http://schemas.microsoft.com/wbem/wsman/1/wsman.xsd',
        'xmlns:rsp' => 'http://schemas.microsoft.com/wbem/wsman/1/windows/shell',
        'xmlns:cfg' => 'http://schemas.microsoft.com/wbem/wsman/1/config',
      }
    end

    def header
      { "#{NS_ADDRESSING}:To" => "#{@xfer.endpoint.to_s}",
        "#{NS_ADDRESSING}:ReplyTo" => {
        "#{NS_ADDRESSING}:Address" => 'http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous',
          :attributes! => {"#{NS_ADDRESSING}:Address" => {'mustUnderstand' => true}}},
        "#{NS_WSMAN_DMTF}:MaxEnvelopeSize" => @max_env_sz,
        "#{NS_ADDRESSING}:MessageID" => "uuid:#{SecureRandom.uuid.to_s.upcase}",
        "#{NS_WSMAN_MSFT}:SessionId" => "uuid:#{@session_id}",
        "#{NS_WSMAN_DMTF}:Locale/" => '',
        "#{NS_WSMAN_MSFT}:DataLocale/" => '',
        "#{NS_WSMAN_DMTF}:OperationTimeout" => Iso8601Duration.sec_to_dur(@operation_timeout),
        :attributes! => {
          "#{NS_WSMAN_DMTF}:MaxEnvelopeSize" => {'mustUnderstand' => true},
          "#{NS_WSMAN_DMTF}:Locale/" => {'xml:lang' => @locale, 'mustUnderstand' => false},
          "#{NS_WSMAN_MSFT}:DataLocale/" => {'xml:lang' => @locale, 'mustUnderstand' => false},
          "#{NS_WSMAN_MSFT}:SessionId" => {'mustUnderstand' => false}
        }}
    end

    # merge the various header hashes and make sure we carry all of the attributes
    #   through instead of overwriting them.
    def merge_headers(*headers)
      hdr = {}
      headers.each do |h|
        hdr.merge!(h) do |k,v1,v2|
          v1.merge!(v2) if k == :attributes!
        end
      end
      hdr
    end

    def send_get_output_message(message)
      send_message(message)
      puts "get output sent"
    rescue WinRMWSManFault => e
      # If no output is available before the wsman:OperationTimeout expires,
      # the server MUST return a WSManFault with the Code attribute equal to
      # 2150858793. When the client receives this fault, it SHOULD issue 
      # another Receive request.
      # http://msdn.microsoft.com/en-us/library/cc251676.aspx
      if e.fault_code == '2150858793'
        logger.debug("[WinRM] retrying receive request after timeout")
        retry
      else
        raise
      end
    end

    def send_message(message)
      @xfer.send_request(message)
    end
    

    # Helper methods for SOAP Headers

    def resource_uri_cmd
      {"#{NS_WSMAN_DMTF}:ResourceURI" => 'http://schemas.microsoft.com/powershell/Microsoft.PowerShell',
        :attributes! => {"#{NS_WSMAN_DMTF}:ResourceURI" => {'mustUnderstand' => true}}}
    end

    def resource_uri_wmi(namespace = 'root/cimv2/*')
      {"#{NS_WSMAN_DMTF}:ResourceURI" => "http://schemas.microsoft.com/wbem/wsman/1/wmi/#{namespace}",
        :attributes! => {"#{NS_WSMAN_DMTF}:ResourceURI" => {'mustUnderstand' => true}}}
    end

    def action_create
      {"#{NS_ADDRESSING}:Action" => 'http://schemas.xmlsoap.org/ws/2004/09/transfer/Create',
        :attributes! => {"#{NS_ADDRESSING}:Action" => {'mustUnderstand' => true}}}
    end

    def action_delete
      {"#{NS_ADDRESSING}:Action" => 'http://schemas.xmlsoap.org/ws/2004/09/transfer/Delete',
        :attributes! => {"#{NS_ADDRESSING}:Action" => {'mustUnderstand' => true}}}
    end

    def action_command
      {"#{NS_ADDRESSING}:Action" => 'http://schemas.microsoft.com/wbem/wsman/1/windows/shell/Command',
        :attributes! => {"#{NS_ADDRESSING}:Action" => {'mustUnderstand' => true}}}
    end

    def action_receive
      {"#{NS_ADDRESSING}:Action" => 'http://schemas.microsoft.com/wbem/wsman/1/windows/shell/Receive',
        :attributes! => {"#{NS_ADDRESSING}:Action" => {'mustUnderstand' => true}}}
    end

    def action_signal
      {"#{NS_ADDRESSING}:Action" => 'http://schemas.microsoft.com/wbem/wsman/1/windows/shell/Signal',
        :attributes! => {"#{NS_ADDRESSING}:Action" => {'mustUnderstand' => true}}}
    end

    def action_send
      {"#{NS_ADDRESSING}:Action" => 'http://schemas.microsoft.com/wbem/wsman/1/windows/shell/Send',
        :attributes! => {"#{NS_ADDRESSING}:Action" => {'mustUnderstand' => true}}}
    end

    def action_enumerate
      {"#{NS_ADDRESSING}:Action" => 'http://schemas.xmlsoap.org/ws/2004/09/enumeration/Enumerate',
        :attributes! => {"#{NS_ADDRESSING}:Action" => {'mustUnderstand' => true}}}
    end

    def selector_shell_id(shell_id)
      {"#{NS_WSMAN_DMTF}:SelectorSet" =>
        {"#{NS_WSMAN_DMTF}:Selector" => shell_id, :attributes! => {"#{NS_WSMAN_DMTF}:Selector" => {'Name' => 'ShellId'}}}
      }
    end

    def uuid_to_bytes(uuid)
      return [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0] if uuid.nil?

      b=[]
      frag_num = 0
      uuid.split("-").each do |frag|
        if frag_num < 3
          len = frag.length-1
          while len > 0 do
            b << frag[len-1..len].to_i(16)
            len = len - 2
          end
        else
          len = 0
          while len < frag.length do
            b << frag[len..len+1].to_i(16)
            len = len + 2
          end
        end
        frag_num += 1
      end
      b
    end

    def psrp_message(shell_id, command_id, message_type, payload)
      payload_bytes = payload.force_encoding('utf-8').bytes

      message = [0,0,0,0]
      message << 0
      message << 0
      message << 0
      message << rand(255)
      # fragmentId
      message += [0,0,0,0,0,0,0,0]
      # end/start fragment
      message << 3
      # blob length
      message += [payload_bytes.length + 43].pack("N").unpack("cccc")
      # blob
      # destination
      message += [2,0,0,0]
      # type
      message += [message_type.to_i(16)].pack("N").unpack("cccc").reverse
      #shell
      message += uuid_to_bytes(shell_id)
      #command
      message += uuid_to_bytes(command_id)
      # BOM
      message += [239,187,191]
      #variable
      message += payload_bytes

      message
    end

    def encode_bytes(bytes)
      Base64.strict_encode64(bytes.pack('C*'))
    end
  end # WinRMWebService
end # WinRM
