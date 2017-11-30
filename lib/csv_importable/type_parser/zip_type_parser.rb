module CSVImportable
  class TypeParser::ZipTypeParser < TypeParser
    def parse_val
      val = value.delete('-')
      not_digits unless val.count('0-9') == val.length
      return value if val.length == 9
      val = '0' + val until val.length >= 5
      val
    end

    def not_digits
      raise
    end

    def error_message
      "Invalid value for column: #{key}. Value should contain only numbers or a dash."
    end
  end
end
