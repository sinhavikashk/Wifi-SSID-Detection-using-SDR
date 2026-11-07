function results = wifi_dsss_rx(x, verbose)
% WIFI_DSSS_RX  802.11b receiver: 1 Mbps (DBPSK + Barker) and 11 / 5.5 Mbps (CCK) long-preamble frames.
%   The PLCP preamble + header is always 1 Mbps; the PSDU can be 1 Mbps (Barker) or 11 / 5.5 Mbps (CCK).
%   Several frames inside one energy burst (e.g. one beacon per SSID of the same AP, back to back)
%   are all decoded.
%
%   results = wifi_dsss_rx(x)            x = complex capture at 20 MS/s (row or column)
%   results = wifi_dsss_rx(x, true)      also prints what happened at every energy burst
%   wifi_dsss_rx('selftest')             decodes the synthetic frames in dsss_test.mat
%   b = wifi_dsss_rx('bursts', x)        list of energy bursts [first_sample last_sample]
%
% results{k}: start (burst start - 400), pay_first / pay_last (first / last sample of the PSDU in x),
%   signal, length_us, hdr_crc_ok, cfo_hz, fcs_ok, psdu (uint8 bytes of the MAC frame incl. FCS),
%   rate_mbps (CCK frames). Pass results{k}.psdu to wifi_rx_ref('parse_mgmt', psdu).
% Base MATLAB only (no toolbox).
  if nargin >= 1 && ischar(x) && strcmp(x, 'selftest')
    selftest();
    return;
  end
  if nargin >= 1 && ischar(x) && strcmp(x, 'bursts')
    xx = double(reshape(verbose, 1, []));            % wifi_dsss_rx('bursts', samples)
    results = find_bursts(xx - mean(xx));            % Nx2: [first_sample last_sample]
    return;
  end
  if nargin < 2, verbose = false; end
  x = double(reshape(x, 1, []));
  x = x - mean(x);
  results = {};
  bursts = find_bursts(x);
  for bi = 1:size(bursts, 1)
    a = bursts(bi, 1); b = bursts(bi, 2);
    lo = max(1, a - 400); hi = min(numel(x), b + 400);
    pos = lo;                                              % where to look for the next preamble
    for guard = 1:16                                       % several frames can sit in one burst
      if guard > 1 && hi - pos < 4000, break; end
      r = demod_burst(x(pos:hi));
      if verbose
        fprintf('  burst %.3f-%.3f ms (frame %d): %s\n', (a-1)/20e3, b/20e3, guard, describe(r));
      end
      if strcmp(r.stage, 'ok')
        r.start = lo;
        r.pay_first = pos - 1 + r.pay_rel(1);
        r.pay_last  = pos - 1 + r.pay_rel(2);
        results{end+1} = r;                                %#ok<AGROW>
      end
      if isfield(r, 'end_rel') && r.end_rel > 0
        pos = pos + r.end_rel;                             % continue right after this frame
      else
        break;
      end
    end
  end
end

function s = describe(r)
  s = r.stage;
  if isfield(r, 'cfo_hz'),            s = sprintf('%s | cfo %.0f Hz', s, r.cfo_hz); end
  if isfield(r, 'sync_ones'),         s = sprintf('%s | ones-run %.2f', s, r.sync_ones); end
  if isfield(r, 'best_sfd_hamming'),  s = sprintf('%s | best SFD distance %d/16', s, r.best_sfd_hamming); end
  if isfield(r, 'signal'),            s = sprintf('%s | SIGNAL 0x%02X LENGTH %d us hdrCRC %d', s, r.signal, r.length_us, r.hdr_crc_ok); end
  if isfield(r, 'fcs_ok'),            s = sprintf('%s | FCS %d', s, r.fcs_ok); end
  if isfield(r, 'rate_mbps'),         s = sprintf('%s | CCK %g Mbps', s, r.rate_mbps); end
  if isfield(r, 'cck_metric'),        s = sprintf('%s | CCK metric %.1f', s, r.cck_metric); end
end

function ref = barker_template()
  barker = [1 -1 1 1 -1 1 1 1 -1 -1 -1];
  ref = barker(floor(((0:19) + 0.5) * 11 / 20) + 1);
end

function bursts = find_bursts(x)
  block = 200; thr = 4.0; min_blocks = 25; max_gap = 3;
  nb = floor(numel(x) / block);
  bursts = zeros(0, 2);
  if nb < 10, return; end
  P = zeros(1, nb);
  step = 20000;
  for c0 = 1:step:nb
    c1 = min(nb, c0 + step - 1);
    seg = x((c0-1)*block + 1 : c1*block);
    P(c0:c1) = mean(reshape(abs(seg).^2, block, c1 - c0 + 1), 1);
  end
  sP = sort(P);
  floorP = sP(max(1, round(0.10 * nb)));
  idx = find(P > thr * floorP);
  if isempty(idx), return; end
  s = idx(1); p = idx(1);
  runs = zeros(0, 2);
  for i = idx(2:end)
    if i - p > max_gap + 1
      runs(end+1, :) = [s p];                     %#ok<AGROW>
      s = i;
    end
    p = i;
  end
  runs(end+1, :) = [s p];
  keep = (runs(:,2) - runs(:,1) + 1) >= min_blocks;
  runs = runs(keep, :);
  bursts = [(runs(:,1) - 1)*block + 1, runs(:,2)*block];
end

function crc = crc16_plcp(bits)
  reg = 65535;
  for k = 1:numel(bits)
    fb = xor(bitand(bitshift(reg, -15), 1), bits(k));
    reg = bitand(bitshift(reg, 1), 65535);
    if fb, reg = bitxor(reg, 4129); end           % 0x1021
  end
  crc = bitand(bitcmp(uint16(reg)), uint16(65535));
  crc = double(crc);
end

function c = crc32_ieee(bytes)
  crc = uint32(4294967295);
  poly = uint32(3988292384);
  for k = 1:numel(bytes)
    crc = bitxor(crc, uint32(bytes(k)));
    for b = 1:8
      if bitand(crc, uint32(1)) == 1
        crc = bitxor(bitshift(crc, -1), poly);
      else
        crc = bitshift(crc, -1);
      end
    end
  end
  c = bitxor(crc, uint32(4294967295));
end

function ok = fcs_ok(psdu)
  ok = false;
  if numel(psdu) < 5, return; end
  t = double(psdu(end-3:end));
  want = t(1) + t(2)*256 + t(3)*65536 + t(4)*16777216;
  ok = (double(crc32_ieee(psdu(1:end-4))) == want);
end

function r = demod_burst(xs)
  SPS = 20;
  ref = barker_template();
  sfd = double(bitand(bitshift(hex2dec('F3A0'), -(0:15)), 1));        % transmitted order, LSB first
  r = struct('stage', 'too short');
  y = filter(ref(end:-1:1), 1, xs);
  c = y(SPS:end);                                 % c(m) = sum_k ref(k) * xs(m+k-1)
  if numel(c) < 200 + SPS, return; end
  amp = abs(c);
  S = zeros(1, SPS);
  for t = 1:SPS
    S(t) = sum(amp(t:SPS:end).^2);
  end
  [~, tau1] = max(S);
  tau = tau1 - 1;                                 % 0-based timing phase
  chunk = 16; off = tau; n = 0;
  cs = zeros(1, 0);
  posv = zeros(1, 0);                              % 0-based index into c of every symbol in cs
  while true
    base = off + n*SPS;
    if base + chunk*SPS + 1 >= numel(c), break; end
    best = 0; bests = -1;
    for sh = [-1 0 1]
      idx = base + sh + SPS*(0:chunk-1);
      if idx(1) < 0 || idx(end) >= numel(c), continue; end
      v = sum(amp(idx + 1));
      if sh == 0, v = v * 1.03; end               % hysteresis
      if v > bests, bests = v; best = sh; end
    end
    off = off + best;
    idx = off + n*SPS + SPS*(0:chunk-1);
    idx = idx(idx < numel(c));
    cs = [cs, c(idx + 1)];                        %#ok<AGROW>
    posv = [posv, idx];                           %#ok<AGROW>
    n = n + chunk;
  end
  if numel(cs) < 200, r.stage = 'too short after tracking'; return; end
  a = abs(cs);
  sa = sort(a);
  p90 = sa(max(1, ceil(0.9*numel(sa))));
  big = a > 0.4 * p90;
  d = cs(2:end) .* conj(cs(1:end-1));
  m = big(2:end) & big(1:end-1);
  if sum(m) < 100, r.stage = 'no strong symbols'; return; end
  theta = angle(sum(d(m).^2)) / 2;                % CFO in rad/symbol
  scr = double(real(d .* exp(-1j*theta)) < 0);    % 1 = phase change
  desc = scr;
  desc(8:end) = mod(scr(8:end) + scr(4:end-4) + scr(1:end-7), 2);
  cfo_hz = theta / (2*pi*1e-6);
  if numel(desc) >= 64
    w64 = conv(desc, ones(1,64)/64, 'valid');
    sync_ones = max(w64);
  else
    sync_ones = 0;
  end
  found = [];
  for i0 = 16:(numel(desc) - 65)
    if isequal(desc(i0+1:i0+16), sfd) && mean(desc(i0-15:i0)) >= 0.8
      found = i0; break;
    end
  end
  if isempty(found)
    best_hd = 99;
    for i0 = 0:(numel(desc) - 16)
      hd = sum(desc(i0+1:i0+16) ~= sfd);
      if hd < best_hd, best_hd = hd; end
    end
    r = struct('stage', 'no SFD', 'sync_ones', sync_ones, 'cfo_hz', cfo_hz, 'best_sfd_hamming', best_hd);
    return;
  end
  h = desc(found+17 : found+64);
  signal = sum(h(1:8) .* 2.^(0:7));
  service = sum(h(9:16) .* 2.^(0:7));
  length_us = sum(h(17:32) .* 2.^(0:15));
  crc = crc16_plcp(h(1:32));
  crc_bits = double(bitand(bitshift(crc, -(15:-1:0)), 1));
  hdr_crc_ok = isequal(h(33:48), crc_bits);
  r = struct('stage', 'header', 'signal', signal, 'service', service, 'length_us', length_us, ...
             'hdr_crc_ok', hdr_crc_ok, 'cfo_hz', cfo_hz, 'sync_ones', sync_ones);
  L = found + 65;                                 % index in cs of the last header symbol
  if L <= numel(posv)
    psdu_start = posv(L) + 1 + 20;                % first sample of the PSDU inside xs (1-based)
    r.pay_rel = [psdu_start, min(numel(xs), psdu_start - 1 + round(length_us*20))];
    if hdr_crc_ok && length_us > 0 && length_us < 20000
      r.end_rel = psdu_start - 1 + round(length_us*20);   % lets the caller look for the next frame
    end
  else
    r.pay_rel = [1, 1];
  end
  if signal == 110 || signal == 55
    if ~hdr_crc_ok || L > numel(posv)
      r.stage = sprintf('CCK frame, header CRC bad (SIGNAL=0x%02X)', signal);
      return;
    end
    r = demod_cck(r, xs, posv, cs, found, theta, scr, service, length_us);
    return;
  end
  if signal ~= 10
    r.stage = sprintf('unsupported rate (SIGNAL=0x%02X)', signal);
    return;
  end
  nbytes = length_us / 8;
  if mod(length_us, 8) ~= 0 || nbytes < 14 || nbytes > 2400
    r.stage = sprintf('bad LENGTH (%d us)', length_us);
    return;
  end
  pb = desc(found+65 : min(numel(desc), found+64+8*nbytes));
  if numel(pb) < 8*nbytes
    r.stage = sprintf('PSDU runs past the burst (%d of %d bits)', numel(pb), 8*nbytes);
    return;
  end
  psdu = uint8(sum(reshape(pb, 8, nbytes) .* (2.^(0:7)'), 1));
  r.stage = 'ok';
  r.psdu = psdu;
  r.fcs_ok = fcs_ok(psdu);
end

function r = demod_cck(r, xs, posv, cs, found, theta, scr, service, length_us)
  % 11 Mbps (8 bits/symbol) or 5.5 Mbps (4 bits/symbol) CCK PSDU. Chips are 11 Mchip/s, the capture is
  % 20 MS/s, so chip centres are interpolated at fractional sample positions (20/11 samples apart).
  % Chip timing comes from the Barker symbol grid of the preamble; a few sub-sample offsets are tried.
  is11 = (r.signal == 110);
  if is11
    nbytes = floor(length_us * 11 / 8);
    if bitand(service, 128), nbytes = nbytes - 1; end   % SERVICE bit 7 = length extension
    nsym = nbytes;
  else
    nbytes = floor(length_us * 11 / 16);
    nsym = 2 * nbytes;
  end
  if nbytes < 14 || nbytes > 2400
    r.stage = sprintf('bad LENGTH (%d us)', length_us);
    return;
  end
  nchips = 8 * nsym;
  L = found + 65;
  t0 = posv(L) + 1 + 20;                              % first sample of the first CCK symbol
  if t0 + nchips * 20 / 11 + 8 > numel(xs)
    r.stage = sprintf('PSDU runs past the burst (CCK, %d bytes)', nbytes);
    return;
  end
  s = 1:numel(xs);
  xd = xs .* exp(-1j * theta * ((s - 0.5) / 20));     % remove the carrier offset (theta = rad per us)
  cL = cs(L) * exp(-1j * theta * ((posv(L) + 10) / 20));
  ref_phase = angle(cL);                              % phase of the last header symbol
  [C, cbits] = cck_codebook(is11);
  DQ = [0 0; 0 1; 1 1; 1 0];                          % DQPSK: phase change 0, +90, 180, -90 deg -> (d0, d1)
  n0 = found + 64;
  r.stage = 'CCK FCS failed';
  best = -1;
  for dl = [0 -0.25 0.25 -0.5 0.5 -0.75 0.75 -1 1]
    p = t0 - 0.5 + ((0:nchips-1) + 0.5) * 20 / 11 + dl;
    R = reshape(interp_x(xd, p), 8, nsym);
    Z = C' * R;                                       % correlation with every code word
    [mag, kk] = max(abs(Z), [], 1);
    ph = angle(Z(sub2ind(size(Z), kk, 1:nsym)));      % phi1 of every symbol
    metric = sum(mag);
    if metric > best, best = metric; r.cck_metric = metric; end
    for par = 0:1                                     % which symbols get the extra 180 degrees
      prev = [ref_phase, ph(1:end-1)];
      dphi = ph - prev - pi * mod((0:nsym-1) + par, 2);
      q = mod(round(dphi / (pi/2)), 4);
      bits = [DQ(q + 1, :), cbits(kk, :)];            % nsym x (2 + 2 or 6) bits, transmit order
      ser = reshape(bits.', 1, []);
      sa = [scr(1:n0), ser];
      ii = n0 + (1:numel(ser));
      dsc = mod(sa(ii) + sa(ii - 4) + sa(ii - 7), 2);
      if numel(dsc) < 8 * nbytes, continue; end
      psdu = uint8(sum(reshape(dsc(1:8*nbytes), 8, nbytes) .* (2.^(0:7)'), 1));
      if fcs_ok(psdu)
        r.stage = 'ok';
        r.psdu = psdu;
        r.fcs_ok = true;
        r.rate_mbps = r.signal / 10;
        r.cck_metric = metric;
        return;
      end
    end
  end
end

function [C, cbits] = cck_codebook(is11)
  % columns of C = code words with phi1 = 0; cbits(k,:) = the data bits that select code word k
  if is11
    K = 64; C = zeros(8, K); cbits = zeros(K, 6); k = 0;
    for a = 0:3
      for b = 0:3
        for c = 0:3
          k = k + 1;
          p2 = a*pi/2; p3 = b*pi/2; p4 = c*pi/2;
          C(:, k) = cck_chips(p2, p3, p4);
          cbits(k, :) = [floor(a/2) mod(a,2) floor(b/2) mod(b,2) floor(c/2) mod(c,2)];
        end
      end
    end
  else
    K = 4; C = zeros(8, K); cbits = zeros(K, 2); k = 0;
    for d2 = 0:1
      for d3 = 0:1
        k = k + 1;
        C(:, k) = cck_chips(d2*pi + pi/2, 0, d3*pi);
        cbits(k, :) = [d2 d3];
      end
    end
  end
end

function c = cck_chips(p2, p3, p4)
  c = [exp(1j*(p2+p3+p4)); exp(1j*(p3+p4)); exp(1j*(p2+p4)); -exp(1j*p4); ...
       exp(1j*(p2+p3));    exp(1j*p3);      -exp(1j*p2);      1];
end

function v = interp_x(x, p)
  % windowed-sinc interpolation of x (1-based samples) at the fractional positions p
  n0 = floor(p); f = p - n0;
  num = zeros(size(p)); den = zeros(size(p));
  for k = -3:4
    a = f - k;
    w = (sin(pi*a) ./ (pi*a + (a == 0)) + (a == 0)) .* (0.5 + 0.5*cos(pi*a/4.5));
    idx = min(max(n0 + k, 1), numel(x));
    num = num + w .* x(idx);
    den = den + w;
  end
  v = num ./ den;
end


function selftest()
  here = fileparts(mfilename('fullpath'));
  f = fullfile(here, 'dsss_test.mat');
  if ~exist(f, 'file'), f = fullfile(pwd, 'dsss_test.mat'); end
  if ~exist(f, 'file')
    fprintf('dsss_test.mat not found next to wifi_dsss_rx.m (or in the current folder).\n');
    return;
  end
  d = load(f);
  all_ok = true;
  for k = 1:d.n_cases
    x = d.(sprintf('x%d', k));
    want = d.(sprintf('psdu%d', k));
    res = wifi_dsss_rx(x);
    good = false;
    for i = 1:numel(res)
      if res{i}.fcs_ok && isequal(res{i}.psdu(:), want(:)), good = true; end
    end
    fprintf('case %d (%s): %s\n', k, strtrim(d.(sprintf('desc%d', k))), pf(good));
    all_ok = all_ok && good;
  end
  if all_ok, fprintf('DSSS SELF-TEST PASSED\n'); else, fprintf('DSSS SELF-TEST FAILED\n'); end
end

function s = pf(t)
  if t, s = 'decoded byte-exact'; else, s = 'FAILED'; end
end