#overridding this method in ActiveSupport::TimeWithZone allows us to get 6 fractional seconds of precision
#for both to_xml and to_json calls

class ActiveSupport::TimeWithZone
  def xmlschema(fraction_digits = 6)
    fraction = if fraction_digits > 0
      ".%i" % time.usec.to_s[0, fraction_digits]
    end

    "#{time.strftime("%Y-%m-%dT%H:%M:%S")}#{fraction}#{formatted_offset(true, 'Z')}"
  end
end