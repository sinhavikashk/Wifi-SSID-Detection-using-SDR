function print_ap_table(aps)
% PRINT_AP_TABLE  Print access points sorted from strongest to weakest, with RSSI and distance.
% A '*' after the RSSI means that capture had ADC clipping: treat that RSSI as unreliable.
  cfg = ap_config();
  if isempty(aps)
    fprintf('\nNo access point decoded.\n');
    return;
  end
  [~, o] = sort([aps.rssi_dbm], 'descend');
  aps = aps(o);
  fprintf('\n=== Access points found (strongest first) ===\n');
  fprintf('%-3s %-24s %-18s %-4s %-8s %-6s %-5s %-10s %-8s\n', '#', 'SSID', 'BSSID', 'Ch', 'Band', 'Frames', 'Gain', 'RSSI(dBm)', 'Dist(m)');
  any_clip = false;
  for i = 1:numel(aps)
    a = aps(i);
    if a.channel > 14, band = '5 GHz'; else, band = '2.4 GHz'; end
    star = ''; if a.clipped, star = '*'; any_clip = true; end
    fprintf('%-3d %-24.24s %-18s %-4d %-8s %-6d %-5d %-10s %-8.1f\n', i, a.ssid, a.bssid, a.channel, ...
            band, a.nframes, a.gain_db, sprintf('%.1f%s', a.rssi_dbm, star), a.dist_m);
  end
  fprintf('\nTotal: %d access point(s).\n', numel(aps));
  fprintf('Distance model: TX %g dBm assumed, path-loss exponent n = %g, CAL_DB = %g (ap_config.m).\n', ...
          cfg.TX_EIRP_DBM, cfg.PATH_EXP, cfg.CAL_DB);
  if any_clip
    fprintf('* = the ADC clipped during that capture (signal too strong): RSSI is unreliable.\n');
  end
  fprintf('RSSI / distance are estimates (walls, reflections, unknown AP power): use as rough guide.\n');
end
