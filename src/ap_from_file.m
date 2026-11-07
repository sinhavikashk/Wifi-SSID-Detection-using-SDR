function aps = ap_from_file(mat_file, gain_db)
% AP_FROM_FILE  Same as hunt_ssids_plus, but on a capture you already saved (no Pluto needed).
%
%   aps = ap_from_file('cap_ch6.mat')            % uses gain_db saved in the file
%   aps = ap_from_file('cap_ch6.mat', 30)        % old file without gain_db: give the gain you used
%
% Prints the table (SSID, BSSID, channel, RSSI, distance), draws the channel graph and saves
% channel_graph_*.png.  Good as the "backup" for demo day.
  d = load(mat_file);
  if nargin < 2 || isempty(gain_db)
    if isfield(d, 'gain_db'), gain_db = d.gain_db; else, gain_db = []; end
  end
  f_mhz = d.fc / 1e6;
  if f_mhz < 3000, ch = round((f_mhz - 2407) / 5); else, ch = round((f_mhz - 5000) / 5); end
  fprintf('File %s: channel %d, %.1f s\n', mat_file, ch, numel(d.raw_iq) / d.fs);
  aps = analyze_capture_aps(d.raw_iq, ch, gain_db);
  print_ap_table(aps);
  if any([aps.channel] <= 14), plot_channel_graph(aps, '2.4', 'channel_graph_2.4GHz.png'); end
  if any([aps.channel] > 14),  plot_channel_graph(aps, '5',   'channel_graph_5GHz.png');  end
end
