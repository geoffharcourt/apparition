# frozen_string_literal: true

require 'uri'
require 'forwardable'
require 'capybara/apparition/chrome_client'
require 'capybara/apparition/launcher'

module Capybara::Apparition
  class Driver < Capybara::Driver::Base
    DEFAULT_TIMEOUT = 30

    extend Forwardable

    attr_reader :app, :options

    delegate %i[restart current_url status_code body
                title frame_title frame_url switch_to_frame
                window_handles close_window open_new_window switch_to_window within_window
                paper_size= zoom_factor=
                scroll_to
                network_traffic clear_network_traffic
                headers headers= add_headers
                cookies remove_cookie clear_cookies cookies_enabled=
                clear_memory_cache
                go_back go_forward refresh
                console_messages] => :browser

    def initialize(app, options = {})
      @app       = app
      @options   = options
      @browser   = nil
      @inspector = nil
      @client    = nil
      @started   = false
    end

    def needs_server?
      true
    end

    # def chrome_url
    #   'ws://localhost:9223'
    # end

    def browser
      @browser ||= begin
        browser = Browser.new(client, browser_logger)
        browser.js_errors = options[:js_errors] if options.key?(:js_errors)
        browser.ignore_https_errors = options[:ignore_https_errors] if options.key?(:ignore_https_errors)
        browser.extensions = options.fetch(:extensions, [])
        browser.debug      = true if options[:debug]
        browser.url_blacklist = options[:url_blacklist] || []
        browser.url_whitelist = options[:url_whitelist] || []
        browser
      end
    end

    def inspector
      @inspector ||= options[:inspector] && Inspector.new(options[:inspector])
    end

    def client
      @client ||= begin
        browser_options = {}
        browser_options['remote-debugging-port'] = options[:port] || 0
        browser_options['remote-debugging-address'] = options[:host] if options[:host]
        browser_options['window-size'] = options[:window_size].join(',') if options[:window_size]
        @launcher ||= Browser::Launcher.start(
          headless: options[:headless] != false,
          browser: browser_options
        )
        ws_url = @launcher.ws_url
        ::Capybara::Apparition::ChromeClient.client(ws_url.to_s)
      end
    end

    def browser_options
      list = options[:browser_options] || []
      # TODO: configure SSL options
      # PhantomJS defaults to only using SSLv3, which since POODLE (Oct 2014)
      # many sites have dropped from their supported protocols (eg PayPal,
      # Braintree).
      # list += ["--ignore-ssl-errors=yes"] unless list.grep(/ignore-ssl-errors/).any?
      # list += ["--ssl-protocol=TLSv1"] unless list.grep(/ssl-protocol/).any?
      # list += ["--remote-debugger-port=#{inspector.port}", "--remote-debugger-autorun=yes"] if inspector
      # Note: Need to verify what Chrome command line options are valid for this
      list
    end

    def quit
      @client&.stop
      @launcher&.stop
    end

    # logger should be an object that responds to puts, or nil
    def logger
      options[:logger] || (options[:debug] && STDERR)
    end

    # logger should be an object that behaves like IO or nil
    def browser_logger
      options.fetch(:browser_logger, $stdout)
    end

    def visit(url)
      @started = true
      browser.visit(url)
    end

    alias html body

    def source
      browser.source.to_s
    end

    def find(method, selector)
      browser.find(method, selector).map { |page_id, id| Capybara::Apparition::Node.new(self, page_id, id) }
    end

    def find_xpath(selector)
      find :xpath, selector.to_s
    end

    def find_css(selector)
      find :css, selector.to_s
    end

    def click(x, y)
      browser.click_coordinates(x, y)
    end

    def evaluate_script(script, *args)
      unwrap_script_result(browser.evaluate(script, *native_args(args)))
    end

    def evaluate_async_script(script, *args)
      unwrap_script_result(browser.evaluate_async(script, session_wait_time, *native_args(args)))
    end

    def execute_script(script, *args)
      browser.execute(script, *native_args(args))
      nil
    end

    def current_window_handle
      browser.window_handle
    end

    def no_such_window_error
      NoSuchWindowError
    end

    def reset!
      browser.reset
      browser.url_blacklist = options[:url_blacklist] || []
      browser.url_whitelist = options[:url_whitelist] || []
      @started = false
    end

    def save_screenshot(path, options = {})
      browser.render(path, options)
    end
    alias render save_screenshot

    def render_base64(format = :png, options = {})
      browser.render_base64(options.merge(format: format))
    end

    def resize(width, height)
      browser.resize(width, height, screen: options[:screen_size])
    end
    alias resize_window resize

    def resize_window_to(handle, width, height)
      within_window(handle) do
        resize(width, height)
      end
    end

    def maximize_window(handle)
      within_window(handle) do
        browser.maximize
      end
    end

    def fullscreen_window(handle)
      within_window(handle) do
        browser.fullscreen
      end
    end

    def window_size(handle)
      within_window(handle) do
        evaluate_script('[window.innerWidth, window.innerHeight]')
      end
    end

    def set_proxy(ip, port, type = 'http', user = nil, password = nil)
      browser.set_proxy(ip, port, type, user, password)
    end

    def add_header(name, value, options = {})
      browser.add_header({ name => value }, { permanent: true }.merge(options))
    end
    alias_method :header, :add_header

    def response_headers
      browser.response_headers.each_with_object({}) do |(key, value), hsh|
        hsh[key.split('-').map(&:capitalize).join('-')] = value
      end
    end

    def set_cookie(name, value=nil, options = {})
      name, value, options = parse_raw_cookie(name) if value.nil?

      options[:name]  ||= name
      options[:value] ||= value
      options[:domain] ||= begin
        if @started
          URI.parse(browser.current_url).host
        else
          URI.parse(default_cookie_host).host || '127.0.0.1'
        end
      end

      browser.set_cookie(options)
    end

    def basic_authorize(user = nil, password = nil)
      browser.set_http_auth(user, password)
      # credentials = ["#{user}:#{password}"].pack('m*').strip
      # add_header('Authorization', "Basic #{credentials}")
    end
    alias_method :authenticate, :basic_authorize

    def debug
      if @options[:inspector]
        # Fall back to default scheme
        scheme = begin
                   URI.parse(browser.current_url).scheme
                 rescue StandardError
                   nil
                 end
        scheme = 'http' if scheme != 'https'
        inspector.open(scheme)
        pause
      else
        raise Error, 'To use the remote debugging, you have to launch the driver ' \
                     'with `:inspector => true` configuration option'
      end
    end

    def pause
      # STDIN is not necessarily connected to a keyboard. It might even be closed.
      # So we need a method other than keypress to continue.

      # In jRuby - STDIN returns immediately from select
      # see https://github.com/jruby/jruby/issues/1783
      # TODO: This limitation is no longer true can we simplify?
      read, write = IO.pipe
      Thread.new do
        IO.copy_stream(STDIN, write)
        write.close
      end

      STDERR.puts "Apparition execution paused. Press enter (or run 'kill -CONT #{Process.pid}') to continue."

      signal = false
      old_trap = trap('SIGCONT') do
        signal = true
        STDERR.puts "\nSignal SIGCONT received"
      end
      # wait for data on STDIN or signal SIGCONT received
      keyboard = IO.select([read], nil, nil, 1) until keyboard || signal

      unless signal
        begin
          input = read.read_nonblock(80) # clear out the read buffer
          puts unless input&.end_with?("\n")
        rescue EOFError, IO::WaitReadable # rubocop:disable Lint/HandleExceptions
          # Ignore problems reading from STDIN.
        end
      end
    ensure
      trap('SIGCONT', old_trap) # Restore the previous signal handler, if there was one.
      STDERR.puts 'Continuing'
    end

    def wait?
      true
    end

    def invalid_element_errors
      [Capybara::Apparition::ObsoleteNode, Capybara::Apparition::MouseEventFailed, Capybara::Apparition::WrongWorld]
    end

    def accept_modal(type, options = {})
      case type
      when :alert
        browser.accept_alert
      when :confirm
        browser.accept_confirm
      when :prompt
        browser.accept_prompt options[:with]
      end

      yield if block_given?

      find_modal(options)
    end

    def dismiss_modal(type, options = {})
      case type
      when :confirm
        browser.dismiss_confirm
      when :prompt
        browser.dismiss_prompt
      end

      yield if block_given?
      find_modal(options)
    end

    def timeout
      client.timeout
    end

    def timeout=(sec)
      client.timeout = sec
    end

    def within_frame(frame_selector)
      warn "Driver#within_frame is deprecated, please use Session#within_frame"

      frame = case frame_selector
      when Capybara::Apparition::Node
        frame_selector
      when Integer
        find_css('iframe')[frame_selector]
      when String
        find_css("iframe[name='#{frame_selector}']")[0]
      else
        raise TypeError, 'Unknown frame selector'
        command("FrameFocus")
      end

      switch_to_frame(frame)
      begin
        yield
      ensure
        switch_to_frame(:parent)
      end
    end

  private

    def parse_raw_cookie(raw)
      parts = raw.split(/;\s*/)
      name, value = parts[0].split('=', 2)
      options = parts[1..-1].each_with_object({}) do |part, opts|
        name, value = part.split('=', 2)
        opts[name.to_sym] = value
      end
      [name, value, options]
    end

    def screen_size
      options[:screen_size] || [1366, 768]
    end

    def find_modal(options)
      timeout_sec   = options.fetch(:wait) { session_wait_time }
      expect_text   = options[:text]
      expect_regexp = expect_text.is_a?(Regexp) ? expect_text : Regexp.escape(expect_text.to_s)
      timer = Capybara::Helpers.timer(expire_in: timeout_sec)
      begin
        modal_text = browser.modal_message
        found_text ||= modal_text
        raise Capybara::ModalNotFound if modal_text.nil? || (expect_text && !modal_text.match(expect_regexp))
      rescue Capybara::ModalNotFound => e
        if timer.expired?
          raise e, 'Timed out waiting for modal dialog. Unable to find modal dialog.' if !found_text
          raise e, 'Unable to find modal dialog' \
                   "#{" with #{expect_text}" if expect_text}" \
                   "#{", did find modal with #{found_text}" if found_text}"
        end
        sleep(0.05)
        retry
      end
      modal_text
    end

    def session_wait_time
      if respond_to?(:session_options)
        session_options.default_max_wait_time
      else
        begin begin
                Capybara.default_max_wait_time
              rescue StandardError
                Capybara.default_wait_time
              end end
      end
    end

    def default_cookie_host
      if respond_to?(:session_options)
        session_options.app_host
      else
        Capybara.app_host
      end || ''
    end

    def native_args(args)
      args.map { |arg| arg.is_a?(Capybara::Apparition::Node) ? arg.native : arg }
    end

    def unwrap_script_result(arg, object_cache = {})
      return object_cache[arg] if object_cache.key? arg

      case arg
      when Array
        object_cache[arg] = []
        object_cache[arg].replace(arg.map { |e| unwrap_script_result(e, object_cache) })
        object_cache[arg]
      when Hash
        if (arg['subtype'] == 'node') && arg['objectId']
          Capybara::Apparition::Node.new(self, browser.current_page, arg['objectId'])
        else
          object_cache[arg] = {}
          arg.each { |k, v| object_cache[arg][k] = unwrap_script_result(v, object_cache) }
          object_cache[arg]
        end
      else
        arg
      end
    end
  end
end
