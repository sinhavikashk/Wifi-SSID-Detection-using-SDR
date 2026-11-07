function capture_pluto(channel, out_path, capture_seconds, lo_offset_hz, gain_db)
% CAPTURE_PLUTO  Capture raw IQ from a WiFi channel (2.4 GHz, or 5 GHz on an unlocked Pluto).
%
%   capture_pluto                                % no arguments = channel 6, 0.5 s
%   capture_pluto(channel)                       % channel 1-13 (2.4 GHz) or 5 GHz channel, saves cap_chN.mat
%   capture_pluto(channel, out_path, seconds)
%   capture_pluto(channel, out_path, seconds, lo_offset_hz)
%   capture_pluto(channel, out_path, seconds, lo_offset_hz, gain_db)   % gain for this capture only
%
%   Channel centre: 2.4 GHz = 2407 + 5*channel MHz (ch 6 -> 2437 MHz); 5 GHz = 5000 + 5*channel MHz
%   (ch 36 -> 5180 MHz). See wifi_channel_freq.m. A stock Pluto tunes 325-3800 MHz only, so the
%   5 GHz channels need the Pluto's extended tuning range (70-6000 MHz) switched on first.
%   Saves raw_iq, fs and fc, plus lost_flags, frame_len and gain_db.
%
%   GAIN: this script uses manual gain (AGC off). The default is GAIN_DB below; the 5th argument
%   overrides it for one capture (hunt_ssids_plus uses this to adapt the gain per channel).
%   The gain used is saved as gain_db: RSSI needs it.
%
%   NOTES
%   - Output type is double scaled to +/-1 = ADC full scale (MathWorks docs). A peak near 1
%     means the ADC is clipping.
%   - 20 MSPS is more than the Pluto's USB 2.0 link can stream continuously (about 4-12 MSPS
%     sustained). Samples inside one buffer are contiguous; samples between buffers can be
%     lost. So we use big buffers (26 ms) and report how many buffers had lost samples. A
%     frame that straddles a lost gap simply isn't decoded; the rest are.
%   - lo_offset_hz (default 0): if you see a big DC/LO-leakage spike in the middle of the
%     spectrum, try 1e6. The radio is tuned that far BELOW the channel and the samples are
%     shifted back digitally, so raw_iq is always centred on the channel.
%   - property names are case-sensitive: rx.Gain (capital G), GainSource = 'Manual'.

  GAIN_DB = 45;                                 % <-- default manual RX gain in dB

  % every argument is optional, so pressing Run or typing just "capture_pluto" works
  if nargin < 1 || isempty(channel), channel = 6; end
  fc = wifi_channel_freq(channel);              % true channel centre (errors on a bad channel)
  if nargin < 3 || isempty(capture_seconds), capture_seconds = 0.5; end
  if nargin < 2 || isempty(out_path), out_path = sprintf('cap_ch%d.mat', channel); end
  if nargin < 4 || isempty(lo_offset_hz), lo_offset_hz = 0; end
  if nargin >= 5 && ~isempty(gain_db), GAIN_DB = gain_db; end
  gain_db = GAIN_DB;                            % the gain actually used (saved with the capture)

  fs = 20e6;                                    % 802.11 OFDM channel bandwidth
  fc_tune = fc - lo_offset_hz;
  frame_len = 524288;                           % 2^19 samples = 26 ms per buffer

  try
    rx = comm.SDRRxPluto( ...
        'CenterFrequency', fc_tune, ...
        'BasebandSampleRate', fs, ...
        'GainSource', 'Manual', ...
        'Gain', GAIN_DB, ...
        'SamplesPerFrame', frame_len, ...
        'OutputDataType', 'double');
  catch err
    extra = '';
    if fc_tune > 3.8e9
      extra = [char(10) ' 3) Channel ' num2str(channel) ' is a 5 GHz channel. A stock Pluto tunes only 325-3800 MHz;' ...
               ' its extended range (70-6000 MHz) must be switched on first.'];
    end
    error('capture_pluto:radio', ['Could not create the PlutoSDR receiver.\n' ...
          ' 1) Is "Communications Toolbox Support Package for ADALM-PLUTO Radio" installed?\n' ...
          ' 2) Is the Pluto plugged in? Try:  findPlutoRadio%s\n' ...
          'MATLAB said: %s'], extra, err.message);
  end

  n_frames = ceil(capture_seconds * fs / frame_len);
  chunks = cell(1, n_frames);
  lost_flags = false(1, n_frames);
  fprintf('Capturing %.2f s on channel %d (radio tuned to %.3f MHz, Gain %d dB)...\n', ...
          capture_seconds, channel, fc_tune/1e6, GAIN_DB);
  tic;
  have_lost_output = true;
  t_first = 0;
  for i = 1:n_frames
    if have_lost_output
      try
        [chunks{i}, valid, lost] = rx();
      catch
        have_lost_output = false;               % this MATLAB release has only 2 outputs
        [chunks{i}, valid] = rx();
        lost = false;
      end
    else
      [chunks{i}, valid] = rx();
      lost = false;
    end
    if ~valid, chunks{i} = zeros(0, 1); end
    lost_flags(i) = logical(lost);
    if i == 1, t_first = toc; end                % first read includes connecting to the radio
  end
  elapsed = toc;
  release(rx);
  lost_flags(1) = false;                        % the first buffer always reports startup loss

  raw_iq = vertcat(chunks{:});
  if lo_offset_hz ~= 0
    % The channel sits at +lo_offset_hz in the captured baseband; multiply by
    % exp(-j*2*pi*lo_offset*n/fs) to bring it back to 0 Hz.
    n = (0:numel(raw_iq)-1).';
    raw_iq = raw_iq .* exp(-1j*2*pi*lo_offset_hz*n/fs);
  end

  save(out_path, 'raw_iq', 'fs', 'fc', 'lost_flags', 'frame_len', 'gain_db');
  fprintf('Saved %d samples (%.2f s of radio time) to %s\n', numel(raw_iq), numel(raw_iq)/fs, out_path);
  if n_frames > 1 && elapsed > t_first
    duty = 100 * ((n_frames - 1) * frame_len / fs) / (elapsed - t_first);
    fprintf('Streaming after the radio connected: %.0f %% of real time (100 %% = no gaps; lower = USB could not keep up)\n', min(duty, 100));
  end
  if have_lost_output
    fprintf('Buffers with lost samples: %d of %d\n', sum(lost_flags), n_frames);
  end
  report_level(raw_iq);
end

function report_level(x)
  % scale-independent-looking report, using the documented scale (+/-1 = ADC full scale)
  pk = max(max(abs(real(x))), max(abs(imag(x))));
  clipfrac = (sum(abs(real(x)) >= 0.998) + sum(abs(imag(x)) >= 0.998)) / (2*numel(x));
  fprintf('Peak I/Q component = %.4f of full scale (%.1f dBFS), clipped samples = %.4f %%\n', ...
          pk, 20*log10(pk), 100*clipfrac);
  if clipfrac > 1e-5
    fprintf('=> TOO STRONG: the ADC is clipping. Lower GAIN_DB (try 10-15 dB less) and capture again.\n');
  elseif pk < 0.02
    fprintf('=> TOO WEAK: peak is below 2%% of full scale. Raise GAIN_DB (try +10) and capture again.\n');
  elseif pk > 0.7
    fprintf('=> Close to clipping. Lower GAIN_DB by 5-10 dB for safety margin.\n');
  else
    fprintf('=> Level looks fine (peak between 2%% and 70%% of full scale, no clipping).\n');
  end
end
