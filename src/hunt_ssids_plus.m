function aps = hunt_ssids_plus(channels, capture_seconds, lo_offset_hz)
% HUNT_SSIDS_PLUS  Live Wi-Fi scan with the PlutoSDR: SSID, BSSID and channel of every access point,
% plus signal strength (RSSI, dBm), estimated distance and a channel graph, with AUTOMATIC GAIN
% per channel.
%
%   hunt_ssids_plus()                  2.4 GHz channels 1:13, 1.0 s each
%   hunt_ssids_plus([1 6 11])          only those channels
%   hunt_ssids_plus('5')               5 GHz (only if your Pluto has the extended tuning range)
%   hunt_ssids_plus('both')            2.4 GHz then 5 GHz
%   hunt_ssids_plus('both', 3.0)       3 s per capture (more beacons caught)
%
% Automatic gain: every channel is first captured at GAIN_START_DB (ap_config.m).
%   - ADC clipped (strong signals)  -> captured again with GAIN_STEP_DB less gain
%   - only noise (weak signals)     -> captured again with GAIN_STEP_DB more gain
% Results from all captures are merged per BSSID (a clean, un-clipped measurement wins).
%
% Output: table of every access point (SSID, BSSID, channel, RSSI, distance), a channel graph
% like a Wi-Fi analyzer app, aps_found.mat and channel_graph_*.png in the current folder.
% Needs: capture_pluto.m (the version with the gain argument), wifi_channel_freq.m,
%        wifi_rx_ref.m, wifi_dsss_rx.m, analyze_capture_aps.m, rssi_to_distance.m,
%        print_ap_table.m, plot_channel_graph.m, ap_config.m

  cfg = ap_config();
  CH_24 = 1:13;
  CH_5  = [36:4:64, 100:4:144, 149:4:165];
  if nargin < 1 || isempty(channels), channels = CH_24; end
  if nargin < 2 || isempty(capture_seconds), capture_seconds = 1.0; end
  if nargin < 3 || isempty(lo_offset_hz), lo_offset_hz = 0; end
  if isstring(channels), channels = char(channels); end
  if ischar(channels)
    switch lower(strtrim(channels))
      case {'2.4', '24'}, channels = CH_24;
      case '5',           channels = CH_5;
      case 'both',        channels = [CH_24, CH_5];
      otherwise
        error('hunt_ssids_plus:band', 'Use ''2.4'', ''5'', ''both'' or a list of channel numbers.');
    end
  end
  channels = reshape(channels, 1, []);                            % a column list works too

  aps = [];
  skip5 = false;

  for ch = channels
    is5 = ch > 14;
    if is5 && skip5, continue; end
    tmp = fullfile(tempdir, sprintf('cap_ch%d.mat', ch));
    g = cfg.GAIN_START_DB;
    tried = [];
    gain_fixed = false;
    while true
      try
        capture_pluto(ch, tmp, capture_seconds, lo_offset_hz, g);
      catch err
        % 1) the radio refused this gain at this frequency ("gain must be between -10 and 62"):
        %    clamp to the allowed range and try once more. This is NOT a tuning problem.
        tok = regexp(err.message, 'between\s+(-?\d+)\s+and\s+(-?\d+)', 'tokens', 'once');
        if ~isempty(tok) && ~gain_fixed
          g_old = g;
          g = min(max(g, str2double(tok{1})), str2double(tok{2}));
          gain_fixed = true;
          fprintf('  gain %d dB is not allowed on channel %d, using %d dB instead\n', g_old, ch, g);
          continue;
        end
        if ~is5, rethrow(err); end
        % 2) the very first 5 GHz capture failed for another reason: the Pluto cannot tune there
        if isempty(tried)
          fprintf(['\n5 GHz skipped: the Pluto could not capture on channel %d.\n' ...
                   'A stock Pluto tunes 325-3800 MHz only. MATLAB said: %s\n\n'], ch, err.message);
          skip5 = true;
        else
          fprintf('  channel %d: extra capture failed (%s), keeping what we have\n', ch, err.message);
        end
        break;
      end
      d = load(tmp);
      [new, lvl] = analyze_capture_aps(d.raw_iq, ch, g);
      clear d
      tried(end+1) = g;                                           %#ok<AGROW>
      for i = 1:numel(new)
        fprintf('  ch%-3d %-5s BSSID=%s  SSID=''%s''  RSSI=%.1f dBm  ~%.1f m\n', ...
                new(i).channel, new(i).phy, new(i).bssid, new(i).ssid, new(i).rssi_dbm, new(i).dist_m);
      end
      aps = merge_aps(aps, new);
      fprintf('channel %d @ %d dB: peak %.3f, clipped %.4f %%, %d access point(s) decoded\n', ...
              ch, g, lvl.peak, 100*lvl.clip_frac, numel(new));

      % choose the next gain (if any)
      g_next = [];
      if lvl.clip_frac > cfg.CLIP_FRAC && g - cfg.GAIN_STEP_DB >= cfg.GAIN_MIN_DB
        g_next = g - cfg.GAIN_STEP_DB;                            % too strong -> less gain
        fprintf('  -> too strong, trying %d dB\n', g_next);
      elseif lvl.peak < cfg.WEAK_PEAK && ~any(tried > g) && g < cfg.GAIN_MAX_DB
        g_next = min(g + cfg.GAIN_STEP_DB, cfg.GAIN_MAX_DB);      % only noise -> more gain (up to the limit)
        fprintf('  -> only noise, trying %d dB\n', g_next);
      end
      if isempty(g_next) || any(tried == g_next) || numel(tried) >= cfg.MAX_CAPTURES, break; end
      g = g_next;
    end
  end

  print_ap_table(aps);
  if isempty(aps), return; end
  save('aps_found.mat', 'aps');
  if any([aps.channel] <= 14), plot_channel_graph(aps, '2.4', 'channel_graph_2.4GHz.png'); end
  if any([aps.channel] > 14),  plot_channel_graph(aps, '5',   'channel_graph_5GHz.png');  end
end

function A = merge_aps(A, B)
  % same BSSID heard in several captures: prefer a capture without clipping, then more frames
  for i = 1:numel(B)
    k = [];
    if ~isempty(A), k = find(strcmp({A.bssid}, B(i).bssid), 1); end
    if isempty(A)
      A = B(i);
    elseif isempty(k)
      A = [A, B(i)];                                              %#ok<AGROW>
    else
      better = (~B(i).clipped && A(k).clipped) || ...
               (B(i).clipped == A(k).clipped && B(i).nframes > A(k).nframes);
      if better, A(k) = B(i); end
    end
  end
end