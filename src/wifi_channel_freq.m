function fc = wifi_channel_freq(ch)
% WIFI_CHANNEL_FREQ  Centre frequency (Hz) of a 20 MHz WiFi channel number.
%   2.4 GHz: channels 1-13        -> (2407 + 5*ch) MHz   (ch 6 = 2437 MHz)
%   5 GHz  : 36-64, 100-144, 149-165 in steps of 4 -> (5000 + 5*ch) MHz (ch 36 = 5180 MHz)
  valid_5g = [36:4:64, 100:4:144, 149:4:165];
  if ~isscalar(ch) || ~isnumeric(ch) || ch ~= round(ch)
    error('wifi_channel_freq:channel', 'channel must be one whole number.');
  end
  if ch >= 1 && ch <= 13
    fc = (2407 + 5*ch) * 1e6;
  elseif any(ch == valid_5g)
    fc = (5000 + 5*ch) * 1e6;
  else
    error('wifi_channel_freq:channel', ...
          ['channel %d is not valid. Use 1-13 (2.4 GHz) or a 5 GHz channel: ' ...
           '36 40 44 48 52 56 60 64 100 104 108 112 116 120 124 128 132 136 140 144 149 153 157 161 165.'], ch);
  end
end
