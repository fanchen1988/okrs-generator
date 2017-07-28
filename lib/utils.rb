module OKRs
  def get_start_time_from_arg time_arg
    begin
      match = time_arg.downcase.match /^(\d+)(d|w)$/
      time_diff = match[1].to_i * 60 * 60 * 24
      diff_unit = match[2]
      Time.now - time_diff * (diff_unit == 'w' ? 7 : 1)
    rescue RuntimeError => e
      raise "Invalid time argument format, should be something like 7d OR 1w"
    end
  end
end
