module Hydra
  module Listener
    class MaximalOutput < Hydra::Listener::Abstract
      def testing_begin(files)
        @output.write "Hydra Testing:\n#{files.inspect}\n"
      end

      def testing_end
        @output.write "\nHydra Completed\n"
      end

      def worker_begin(worker)
        @output.write "\nHydra worker #{worker.inspect} began\n"
      end

      def worker_end(worker)
        @output.write "\nHydra worker #{worker.inspect} ended\n"
      end

      def file_begin(file)
        @output.write "\nHydra beginning file #{file.inspect}\n"
      end

      def file_end(file, output)
        @output.write output
      end
    end
  end
end
