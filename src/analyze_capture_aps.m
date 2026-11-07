function [aps, lvl] = analyze_capture_aps(raw_iq, cap_channel, gain_db)
% ANALYZE_CAPTURE_APS  Decode beacons / probe responses in one capture and, for every access
% point (BSSID), measure its signal strength (RSSI, dBm) and estimate its distance.
%
%   [aps, lvl] = analyze_capture_aps(raw_iq, cap_channel, gain_db)
%
%   raw_iq       complex samples at 20 MS/s (scaled +/-1 = ADC full scale, as capture_pluto saves)
%   cap_channel  Wi-Fi channel the Pluto was tuned to (1-13 or 5 GHz channel number)
%   gain_db      manual RX gain used for the capture (capture_pluto saves it as gain_db)
%
%   aps is a struct array, one element per BSSID, with fields:
%     ssid, bssid, channel, freq_mhz, nframes (FCS-verified frames used), phy,
%     rssi_dbm (median over the frames), rssi_max_dbm, dist_m,
%     gain_db (gain of this capture), clipped (true = the ADC clipped: RSSI/decoding less reliable)
%   lvl: struct with peak (0..1 of full scale) and clip_frac (fraction of clipped samples).
%
%   How RSSI is measured: for every decoded frame, average power |x|^2 over a window that is
%   inside the frame (OFDM: the preamble STF+LTF; DSSS / CCK: the middle 90 % of the PSDU), minus the
%   noise-floor power, in dBFS.   RSSI(dBm) = power_dBFS - gain_db + CAL_DB   (CAL_DB: ap_config.m)
%   Needs wifi_rx_ref.m, wifi_dsss_rx.m, wifi_channel_freq.m, ap_config.m, rssi_to_distance.m.

  cfg = ap_config();
  if nargin < 3 || isempty(gain_db)
    gain_db = cfg.GAIN_DB_FALLBACK;
    fprintf('  (no gain_db given/saved -> assuming %g dB; set it right or RSSI will be off)\n', gain_db);
  end

  lvl = level_stats(raw_iq);
  clipped = lvl.clip_frac > cfg.CLIP_FRAC;

  x = double(reshape(raw_iq, 1, []));
  N = numel(x);
  dc = mean(x(1:min(N, 4000000)));                 % LO leakage / DC offset (same as wifi_rx_ref)
  noiseP = noise_power(x, dc);

  rec = struct('bssid', {}, 'ssid', {}, 'channel', {}, 'rssi', {}, 'phy', {});

  % ---- OFDM frames: power over the preamble (160 samples STF + 128 samples LTF) ------------
  ofdm = wifi_rx_ref('decode_capture', x);
  for i = 1:numel(ofdm)
    r = ofdm{i};
    if ~r.fcs_ok, continue; end
    m = wifi_rx_ref('parse_mgmt', r.psdu);
    if isempty(m), continue; end
    a = r.t0 - 160; b = r.t0 + 127;                % r.t0 = first long-training symbol
    if a < 1 || b > N, continue; end
    rec(end+1) = make_rec(m, cap_channel, window_dbfs(x, a, b, dc, noiseP) - gain_db + cfg.CAL_DB, 'OFDM'); %#ok<AGROW>
  end

  % ---- DSSS / CCK (802.11b) frames: power over the PSDU of each frame -----------------------
  if cap_channel <= 14
    dsss = wifi_dsss_rx(x);
    bursts = [];
    for i = 1:numel(dsss)
      r = dsss{i};
      if ~r.fcs_ok, continue; end
      m = wifi_rx_ref('parse_mgmt', r.psdu);
      if isempty(m), continue; end
      if isfield(r, 'pay_first')                         % new wifi_dsss_rx: exact PSDU position
        len = r.pay_last - r.pay_first + 1;
        a = r.pay_first + round(0.05*len);
        b = r.pay_last  - round(0.05*len);
      else                                               % old wifi_dsss_rx: whole energy burst
        if isempty(bursts), bursts = wifi_dsss_rx('bursts', x); end
        k = find(max(1, bursts(:,1) - 400) == r.start, 1);
        if isempty(k), continue; end
        len = bursts(k,2) - bursts(k,1) + 1;
        a = bursts(k,1) + round(0.1*len);
        b = bursts(k,2) - round(0.1*len);
      end
      if a < 1 || b > N || b <= a, continue; end
      phy = 'DSSS';
      if isfield(r, 'rate_mbps'), phy = sprintf('CCK%g', r.rate_mbps); end
      rec(end+1) = make_rec(m, cap_channel, window_dbfs(x, a, b, dc, noiseP) - gain_db + cfg.CAL_DB, phy); %#ok<AGROW>
    end
  end

  % ---- one row per BSSID -------------------------------------------------------------------
  aps = struct('ssid', {}, 'bssid', {}, 'channel', {}, 'freq_mhz', {}, 'nframes', {}, ...
               'phy', {}, 'rssi_dbm', {}, 'rssi_max_dbm', {}, 'dist_m', {}, ...
               'gain_db', {}, 'clipped', {});
  if isempty(rec), return; end
  [ub, ~, idx] = unique({rec.bssid});
  for k = 1:numel(ub)
    sel = (idx(:).' == k);
    rs = [rec(sel).rssi];
    first = rec(find(sel, 1));
    ch = first.channel;
    try
      f_mhz = wifi_channel_freq(ch) / 1e6;
    catch
      ch = cap_channel;                            % beacon gave a strange channel number
      f_mhz = wifi_channel_freq(ch) / 1e6;
    end
    med = median(rs);
    aps(end+1) = struct('ssid', first.ssid, 'bssid', ub{k}, 'channel', ch, 'freq_mhz', f_mhz, ...
                        'nframes', numel(rs), 'phy', first.phy, 'rssi_dbm', med, ...
                        'rssi_max_dbm', max(rs), 'dist_m', rssi_to_distance(med, f_mhz), ...
                        'gain_db', gain_db, 'clipped', clipped); %#ok<AGROW>
  end
end

function r = make_rec(m, cap_channel, rssi, phy)
  ch = cap_channel;
  if ~isempty(m.channel), ch = double(m.channel); end   % the AP's own channel, from its beacon
  r = struct('bssid', m.bssid, 'ssid', wifi_rx_ref('ssid_text', m.ssid), ...
             'channel', ch, 'rssi', rssi, 'phy', phy);
end

function db = window_dbfs(x, a, b, dc, noiseP)
  % average power of x(a:b) minus the noise power, in dBFS
  p = mean(abs(x(a:b) - dc).^2) - noiseP;
  db = 10*log10(max(p, 1e-12));
end

function p = noise_power(x, dc)
  % noise floor = 10th percentile of the power of 5 us blocks (100 samples)
  block = 100;
  nb = floor(numel(x) / block);
  P = zeros(1, nb);
  step = 40000;
  for c0 = 1:step:nb
    c1 = min(nb, c0 + step - 1);
    seg = x((c0-1)*block + 1 : c1*block) - dc;
    P(c0:c1) = mean(reshape(abs(seg).^2, block, c1 - c0 + 1), 1);
  end
  sP = sort(P);
  p = sP(max(1, round(0.10 * nb)));
end

function s = level_stats(raw_iq)
  % peak and clipped fraction, in chunks (keeps memory low)
  n = numel(raw_iq); pk = 0; nclip = 0; step = 4000000;
  for a = 1:step:n
    seg = raw_iq(a:min(n, a + step - 1));
    re = abs(real(seg)); im = abs(imag(seg));
    pk = max([pk, max(re), max(im)]);
    nclip = nclip + nnz(re >= 0.998) + nnz(im >= 0.998);
  end
  s.peak = double(pk);
  s.clip_frac = nclip / (2 * max(n, 1));
end