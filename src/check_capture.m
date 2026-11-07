function check_capture(mat_file, seconds, make_plots)
% CHECK_CAPTURE  Inspect a capture made by capture_pluto: level, WiFi activity, decode, SSIDs.
%
%   check_capture                         % looks at cap_ch6.mat, first 0.5 s
%   check_capture('cap_ch6.mat')
%   check_capture('cap_ch6.mat', 1.0)     % look at the first 1 s
%   check_capture('cap_ch6.mat', 0.5, false)   % no plots
%
% Prints: level (clipping / too weak), energy bursts, every OFDM (802.11a/g) frame and every
% 802.11b frame (DSSS 1 Mbps or CCK 5.5 / 11 Mbps) that decodes with a good FCS, and every SSID seen.
% Needs wifi_rx_ref.m and wifi_dsss_rx.m beside it.

  if nargin < 1 || isempty(mat_file), mat_file = 'cap_ch6.mat'; end
  if nargin < 2 || isempty(seconds), seconds = 0.5; end
  if nargin < 3 || isempty(make_plots), make_plots = true; end

  d = load(mat_file, 'raw_iq', 'fs');
  fs = d.fs;
  n = min(numel(d.raw_iq), round(seconds*fs));
  x = double(d.raw_iq(1:n));
  x = x(:).';
  fprintf('File %s: using the first %d samples (%.2f s at %.0f MS/s)\n', mat_file, n, n/fs, fs/1e6);

  % ---- level -----------------------------------------------------------------------------
  pk = max(max(abs(real(x))), max(abs(imag(x))));
  clipfrac = (sum(abs(real(x)) >= 0.998) + sum(abs(imag(x)) >= 0.998)) / (2*n);
  fprintf('\n[1] LEVEL: peak I/Q component = %.4f of full scale (%.1f dBFS); clipped samples = %.4f %%\n', ...
          pk, 20*log10(pk), 100*clipfrac);
  if clipfrac > 1e-5
    fprintf('    TOO STRONG (ADC clipping). Lower GAIN_DB in capture_pluto.m by 10-15 dB, recapture.\n');
  elseif pk < 0.02
    fprintf('    TOO WEAK. Raise GAIN_DB by about 10 dB, recapture.\n');
  elseif pk > 0.7
    fprintf('    Close to clipping. Lower GAIN_DB by 5-10 dB for margin.\n');
  else
    fprintf('    Level is fine.\n');
  end

  % ---- activity: power in 100 microsecond blocks ----------------------------------------
  bl = 2000;
  nb = floor(n/bl);
  P = mean(reshape(abs(x(1:nb*bl)).^2, bl, nb), 1);
  floorP = median(P);
  active = P > 10*floorP;
  edges = sum(diff([0 active 0]) == 1);
  fprintf('\n[2] ACTIVITY: noise floor %.1f dBFS; %d bursts of energy (>10 dB over the floor); %.1f %% of the time active\n', ...
          10*log10(floorP + eps), edges, 100*mean(active));
  if edges == 0
    fprintf('    No bursts at all. Wrong channel / antenna not connected / gain far too low?\n');
  end

  bssids = {}; ssids = {}; phys = {};

  % ---- OFDM decode -----------------------------------------------------------------------
  fprintf('\n[3] OFDM (802.11a/g) frames:\n');
  tic;
  res = wifi_rx_ref('decode_capture', x);
  fprintf('    %d frames found, decoded in %.1f s\n', numel(res), toc);
  n_ok = 0; n_mgmt = 0; rates = [];
  for i = 1:numel(res)
    r = res{i};
    if ~r.fcs_ok, continue; end
    n_ok = n_ok + 1;
    rates(end+1) = r.mbps;                                  %#ok<AGROW>
    m = wifi_rx_ref('parse_mgmt', r.psdu);
    if ~isempty(m)
      n_mgmt = n_mgmt + 1;
      [bssids, ssids, phys] = note_ap(bssids, ssids, phys, m, sprintf('OFDM %d Mbps', r.mbps));
    end
  end
  fprintf('    FCS-valid OFDM frames: %d; beacon/probe-response frames among them: %d\n', n_ok, n_mgmt);
  if n_ok > 0
    fprintf('    OFDM rates seen: %s Mbps\n', mat2str(unique(rates)));
  end

  % ---- DSSS decode -----------------------------------------------------------------------
  fprintf('\n[4] 802.11b frames (DSSS 1 Mbps / CCK 5.5 and 11 Mbps) -- per-burst diagnostics:\n');
  tic;
  dres = wifi_dsss_rx(x, true);
  fprintf('    %d frames reached a PSDU, decoded in %.1f s\n', numel(dres), toc);
  d_ok = 0; d_mgmt = 0;
  for i = 1:numel(dres)
    r = dres{i};
    if ~r.fcs_ok, continue; end
    d_ok = d_ok + 1;
    m = wifi_rx_ref('parse_mgmt', r.psdu);
    if ~isempty(m)
      d_mgmt = d_mgmt + 1;
      phy = 'DSSS 1 Mbps';
      if isfield(r, 'rate_mbps'), phy = sprintf('CCK %g Mbps', r.rate_mbps); end
      [bssids, ssids, phys] = note_ap(bssids, ssids, phys, m, phy);
    end
  end
  fprintf('    FCS-valid 802.11b frames: %d; beacon/probe-response frames among them: %d\n', d_ok, d_mgmt);

  % ---- summary ---------------------------------------------------------------------------
  fprintf('\n[5] ACCESS POINTS SEEN (FCS-verified beacons / probe responses):\n');
  if isempty(bssids)
    fprintf('    none\n');
  end
  for i = 1:numel(bssids)
    fprintf('    SSID=''%s''   BSSID=%s   (%s)\n', ssids{i}, bssids{i}, phys{i});
  end
  fprintf('\n[6] READING THE RESULT:\n');
  if isempty(bssids) && edges > 0
    fprintf('    Energy is there but no beacon decoded. Look at the per-burst lines in [4]:\n');
    fprintf('      "no SFD" with a small SFD distance -> timing / carrier-frequency-offset problem;\n');
    fprintf('      "unsupported rate" -> the AP beacons at a rate this receiver does not handle yet;\n');
    fprintf('      level problems (see [1]) or frames cut by lost-sample gaps are the other usual causes.\n');
  elseif ~isempty(bssids)
    fprintf('    SSID decoding works on this capture.\n');
  end

  % ---- plots -----------------------------------------------------------------------------
  if make_plots
    figure;
    subplot(2,1,1);
    plot((0:nb-1)*bl/fs*1e3, 10*log10(P + eps));
    xlabel('time (ms)'); ylabel('power per 100 us (dBFS)'); title('Energy bursts (WiFi frames show as spikes)');
    grid on;
    subplot(2,1,2);
    nfft = 1024; nseg = min(floor(n/nfft), 4000);
    w = 0.5 - 0.5*cos(2*pi*(0:nfft-1)/nfft);
    S = zeros(1, nfft);
    for k = 1:nseg
      seg = x((k-1)*nfft+1 : k*nfft) .* w;
      S = S + abs(fft(seg)).^2;
    end
    S = fftshift(S/nseg);
    plot(((-nfft/2):(nfft/2-1))*fs/nfft/1e6, 10*log10(S + eps));
    xlabel('baseband frequency (MHz)'); ylabel('dB'); title('Average spectrum');
    grid on;
  end
end

function [bssids, ssids, phys] = note_ap(bssids, ssids, phys, m, phy)
  if ~any(strcmp(bssids, m.bssid))
    bssids{end+1} = m.bssid;                                %#ok<AGROW>
    ssids{end+1} = wifi_rx_ref('ssid_text', m.ssid);        %#ok<AGROW>
    phys{end+1} = sprintf('%s %s, channel field %s', m.subtype, phy, mat2str(m.channel));   %#ok<AGROW>
  end
end