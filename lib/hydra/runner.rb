require 'test/unit'
require 'test/unit/testresult'
Test::Unit.run = true

module Hydra #:nodoc:
  # Hydra class responsible for running test files.
  #
  # The Runner is never run directly by a user. Runners are created by a
  # Worker to run test files.
  #
  # The general convention is to have one Runner for each logical processor
  # of a machine.
  class Runner
    include Hydra::Messages::Runner
    traceable('RUNNER')
    # Boot up a runner. It takes an IO object (generally a pipe from its
    # parent) to send it messages on which files to execute.
    def initialize(opts = {})
      @io = opts.fetch(:io) { raise "No IO Object" } 
      @verbose = opts.fetch(:verbose) { false }      
      $stdout.sync = true
      trace 'Booted. Sending Request for file'

      @io.write RequestFile.new
      begin
        process_messages
      rescue => ex
        trace ex.to_s
        raise ex
      end
    end

    # Run a test file and report the results
    def run_file(file)
      trace "Running file: #{file}"

      output = ""
      if file =~ /_spec.rb$/i
        output, stats = run_rspec_file(file)
      elsif file =~ /_testspec.rb$/i
        output, stats = run_test_spec_file(file)
      elsif file =~ /.feature$/i
        output, stats = run_cucumber_file(file)
      elsif file =~ /.js$/i or file =~ /.json$/i
        output, stats = run_javascript_file(file)
      else
        output, stats = run_test_unit_file(file)
      end

      output = "." if output == ""

      @io.write Results.new(
        :output => output,
        :file   => file,
        :stats  => stats
      )
      return output
    end

    # Stop running
    def stop
      @running = false
    end

    private

    # The runner will continually read messages and handle them.
    def process_messages
      trace "Processing Messages"
      @running = true
      while @running
        begin
          message = @io.gets
          if message and !message.class.to_s.index("Worker").nil?
            trace "Received message from worker"
            trace "\t#{message.inspect}"
            message.handle(self)
          else
            @io.write Ping.new
          end
        rescue IOError => ex
          trace "Runner lost Worker"
          @running = false
        end
      end
    end

    def format_ex_in_file(file, ex)
      "Error in #{file}:\n  #{format_exception(ex)}"
    end

    def format_exception(ex)
      "#{ex.class.name}: #{ex.message}\n    #{ex.backtrace.join("\n    ")}"
    end

    # Run all the Test::Unit Suites in a ruby file
    def run_test_unit_file(file)
      begin
        require file
      rescue LoadError => ex
        trace "#{file} does not exist [#{ex.to_s}]"
        return ex.to_s
      rescue Exception => ex
        trace "Error requiring #{file} [#{ex.to_s}]"
        return format_ex_in_file(file, ex)
      end
      output = []
      @result = Test::Unit::TestResult.new
      @result.add_listener(Test::Unit::TestResult::FAULT) do |value|
        output << `hostname`.chomp
        output << value
      end

      klasses = Runner.find_classes_in_file(file)
      begin
        klasses.each{|klass| klass.suite.run(@result){|status, name| ;}}
      rescue => ex
        output << `hostname`.chomp
        output << format_ex_in_file(file, ex)
      end
      stats = {
        :tests      => @result.run_count,
        :assertions => @result.assertion_count,
        :failures   => @result.failure_count,
        :errors     => @result.error_count,
      }

      return output.join("\n"), stats
    end

    # Run all the test/spec file
    def run_test_spec_file(file)
      begin
        require file
      rescue LoadError => ex
        trace "#{file} does not exist [#{ex.to_s}]"
        return ex.to_s
      rescue Exception => ex
        trace "Error requiring #{file} [#{ex.to_s}]"
        return format_ex_in_file(file, ex)
      end
      output = []
      @result = Test::Unit::TestResult.new
      @result.add_listener(Test::Unit::TestResult::FAULT) do |value|
        output << `hostname`.chomp
        output << value
      end

      klasses = Runner.find_test_spec_classes_in_file(file)
      begin
        klasses.each{|klass| klass.suite.run(@result){|status, name| ;}}
      rescue => ex
        output << `hostname`.chomp
        output << format_ex_in_file(file, ex)
      end

      stats = {
        :tests      => @result.run_count,
        :assertions => @result.assertion_count,
        :failures   => @result.failure_count,
        :errors     => @result.error_count,
      }

      return output.join("\n"), stats
    end

    # run all the Specs in an RSpec file (NOT IMPLEMENTED)
    def run_rspec_file(file)
      # pull in rspec
      begin
        require 'rspec'
        require 'hydra/spec/hydra_formatter'
        # Ensure we override rspec's at_exit
        require 'hydra/spec/autorun_override'
      rescue LoadError => ex
        return ex.to_s
      end
      hydra_output = StringIO.new

      config = [
        '-f', 'RSpec::Core::Formatters::HydraFormatter',
        file
      ]

      RSpec.instance_variable_set(:@world, nil)
      RSpec::Core::Runner.run(config, hydra_output, hydra_output)

      hydra_output.rewind
      output = hydra_output.read.chomp
      output = "" if output.gsub("\n","") =~ /^\.*$/

      return output
    end

    # run all the scenarios in a cucumber feature file
    def run_cucumber_file(file)

      files = [file]
      dev_null = StringIO.new
      hydra_response = StringIO.new

      unless @cuke_runtime
        require 'cucumber'
        require 'hydra/cucumber/formatter'
        Cucumber.logger.level = Logger::INFO
        @cuke_runtime = Cucumber::Runtime.new
        @cuke_configuration = Cucumber::Cli::Configuration.new(dev_null, dev_null)
        @cuke_configuration.parse!(['features']+files)

        support_code = Cucumber::Runtime::SupportCode.new(@cuke_runtime, @cuke_configuration.guess?)
        support_code.load_files!(@cuke_configuration.support_to_load + @cuke_configuration.step_defs_to_load)
        support_code.fire_hook(:after_configuration, @cuke_configuration)
        # i don't like this, but there no access to set the instance of SupportCode in Runtime
        @cuke_runtime.instance_variable_set('@support_code',support_code)
      end
      cuke_formatter = Cucumber::Formatter::Hydra.new(
        @cuke_runtime, hydra_response, @cuke_configuration.options
      )

      cuke_runner ||= Cucumber::Ast::TreeWalker.new(
        @cuke_runtime, [cuke_formatter], @cuke_configuration
      )
      @cuke_runtime.visitor = cuke_runner

      loader = Cucumber::Runtime::FeaturesLoader.new(
        files,
        @cuke_configuration.filters,
        @cuke_configuration.tag_expression
      )
      features = loader.features
      tag_excess = tag_excess(features, @cuke_configuration.options[:tag_expression].limits)
      @cuke_configuration.options[:tag_excess] = tag_excess

      cuke_runner.visit_features(features)

      hydra_response.rewind
      return hydra_response.read
    end

    def run_javascript_file(file)
      errors = []
      require 'v8'
      V8::Context.new do |context|
        context.load(File.expand_path(File.join(File.dirname(__FILE__), 'js', 'lint.js')))
        context['input'] = lambda{
          File.read(file)
        }
        context['reportErrors'] = lambda{|js_errors|
          js_errors.each do |e|
            e = V8::To.rb(e)
            errors << "\n\e[1;31mJSLINT: #{file}\e[0m"
            errors << "  Error at line #{e['line'].to_i + 1} " + 
              "character #{e['character'].to_i + 1}: \e[1;33m#{e['reason']}\e[0m"
            errors << "#{e['evidence']}"
          end
        }
        context.eval %{
          JSLINT(input(), {
            sub: true,
            onevar: true,
            eqeqeq: true,
            plusplus: true,
            bitwise: true,
            regexp: true,
            newcap: true,
            immed: true,
            strict: true,
            rhino: true
          });
          reportErrors(JSLINT.errors);
        }
      end

      if errors.empty?
        return '.'
      else
        return errors.join("\n")
      end
    end

    def self.find_test_spec_classes_in_file(f)
      require f
      ks = Test::Spec::CONTEXTS.values.map{|k| k.testcase}
      Test::Spec::CONTEXTS.clear
      Test::Spec::SHARED_CONTEXTS.clear
      ks
    end

    # find all the test unit classes in a given file, so we can run their suites
    def self.find_classes_in_file(f)
      code = ""
      File.open(f) {|buffer| code = buffer.read}
      matches = code.scan(/class\s+([\S]+)/)
      klasses = matches.collect do |c|
        begin
          if c.first.respond_to? :constantize
            c.first.constantize
          else
            eval(c.first)
          end
        rescue NameError
          # means we could not load [c.first], but thats ok, its just not
          # one of the classes we want to test
          nil
        rescue SyntaxError
          # see above
          nil
        end
      end
      return klasses.select{|k| k.respond_to? 'suite'}
    end

    # Yanked a method from Cucumber
    def tag_excess(features, limits)
      limits.map do |tag_name, tag_limit|
        tag_locations = features.tag_locations(tag_name)
        if tag_limit && (tag_locations.length > tag_limit)
          [tag_name, tag_limit, tag_locations]
        else
          nil
        end
      end.compact
    end
  end
end
