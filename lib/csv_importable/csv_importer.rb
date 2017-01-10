require 'csv'

module CSVImportable
  class CSVImporter
    include CSVImportable::CSVCoercion
    attr_reader :file_string, :should_replace, :out, :results,
                :import_obj

    BIG_FILE_THRESHOLD = 10

    module Statuses
      SUCCESS = :success
      ERROR = :error
    end

    def initialize(args = {})
      @file_string = args[:file_string]
      import_id = args[:import_id]
      @import_obj = Import.find(import_id) if import_id
      # because we can't pass file_string to delayed job
      @file_string = @import_obj.read_file if @import_obj
      @should_replace = args.fetch(:should_replace, false)
      after_init(args)
      require_args
    end

    def out
      @out ||= StringIO.new
    end

    def import
      @results = guard_against_errors do
        destroy_records if should_replace?
        print(starting_message)
        before_rows
        @results = parse_csv_string(file_string) do |row, headers|
          process_row(row, headers)
        end
        after_rows
        print(finished_message)
        @results
      end
      finish_background_job if processing_in_background?
      @results
    end

    def big_file?
      parse_csv_string(file_string).count > BIG_FILE_THRESHOLD
    end

    def succeeded?
      results[:status] == Statuses::SUCCESS
    end

    def number_imported
      results.fetch(:results).length
    end

    private

      def after_init(args = {})
        # hook for subclasses
      end

      def require_args
        required_args.each do |required_arg|
          fail "#{required_arg} is required for #{self.class.name}" unless send(required_arg)
        end
      end

      def finish_background_job
        print "Updating import object and triggering email..."
        import_obj.results = results
        succeeded? ? import_obj.success!(number_imported) : import_obj.fail!
        import_obj.finished_background_job!
        print "Done."
      end

      def before_rows
        # hook for subclasses
      end

      def after_rows
        # hook for subclasses
      end

      def required_args
        [:file_string] + subclass_required_args
      end

      def subclass_required_args
        # hook for subclasses
        []
      end

      def should_replace?
        @should_replace
      end

      def processing_in_background?
        return false unless import_obj.present?
        import_obj.processing_in_background?
      end

      def destroy_records
        # hook for subclasses
      end

      def process_row
        fail 'process_row method is required by subclasses'
      end

      def starting_message
        "Importing with #{self.class.name}...\n\n"
      end

      def finished_message
        "Finished importing."
      end

      def print(message)
        out.print message
        Delayed::Worker.logger.info(message) if processing_in_background?
      end

      def guard_against_errors(&block)

        results = {}

        begin
          ActiveRecord::Base.transaction do
            import_results = yield
            status = import_results.any? { |result| result[:status] == Statuses::ERROR } ? Statuses::ERROR : Statuses::SUCCESS

            results = {
              status: status,
              results: import_results
            }

            # need to rollback if errors
            raise ActiveRecord::Rollback if status == Statuses::ERROR
          end
        rescue Exception => e
          results = {
            status: Statuses::ERROR,
            error: e.message
          }
        end

        print_results(results)

        results
      end

      def print_results(results)
        case results[:status]
        when Statuses::SUCCESS
          print("Imported completed successfully!".green)
        when Statuses::ERROR
          print("\nImported failed, all changes have been rolled back.\n\n".red)
          if results[Statuses::ERROR]
            print("  #{results[Statuses::ERROR]}\n\n".red)
          else
            results[:results].each { |result| print(" #{result}\n") }
          end
        end
      end

      def load_csv_from_file(str)
        csv = CSV.parse(str, headers: true)
        raise(IOError.new('There is no data to import')) if csv.length == 0
        headers = csv.headers.compact
        [csv, headers]
      end

      def parse_csv_string(csv_str, results=[], &block)

        csv, headers = load_csv_from_file(csv_str)

        idx = 1
        csv.each.map do |row|
          errors = []
          begin
            yield row, headers
          rescue Exception => e
            errors << e.message
          end

          result = results.detect(lambda { {} }) { |result| result[:row] == idx+1 }

          {
            row:    idx += 1,
            status: errors.any? ? Statuses::ERROR : result.fetch(:status, Statuses::SUCCESS),
            errors: result.fetch(:errors, []) + errors
          }
        end
      end

      def has_errors?
        results.any? { |result| result[:status] == :error }
      end
  end
end