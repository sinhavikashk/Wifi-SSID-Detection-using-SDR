function plot_channel_graph(aps, band, png_path)
% PLOT_CHANNEL_GRAPH  "Channel graph" like a Wi-Fi analyzer app: one filled arch per access point,
% centred on its channel, as tall as its signal strength (dBm), labelled  SSID (~distance m).
%
%   plot_channel_graph(aps)                 % 2.4 GHz graph
%   plot_channel_graph(aps, '5')            % 5 GHz graph
%   plot_channel_graph(aps, '2.4', 'graph24.png')   % also save a picture
%
%   aps = struct array from analyze_capture_aps / hunt_ssids_plus.
%   Arch width = one 20 MHz channel (the receiver only sees 20 MHz). 2.4 GHz: 4 channel numbers
%   wide (ch 6 -> 4..8). 5 GHz: one slot per 20 MHz channel, same channel order as the app.

  if nargin < 2 || isempty(band), band = '2.4'; end
  is5 = strcmp(band, '5');
  CH_5 = [36:4:64, 100:4:144, 149:4:165];
  FLOOR = -100; TOP = -20;

  if isempty(aps)
    sel = false(1, 0);
  else
    sel = ([aps.channel] > 14) == is5;
  end
  A = aps(sel);

  if is5
    half = 0.5; xl = [0 numel(CH_5) + 1]; xt = 1:numel(CH_5); xtl = CH_5; tol = 3.0;
    pos = zeros(1, numel(A));
    for i = 1:numel(A)
      k = find(CH_5 == A(i).channel, 1);
      if isempty(k), pos(i) = NaN; else, pos(i) = k; end
    end
    ttl = 'Channel Graph - 5 GHz';
  else
    half = 2; xl = [-1 15]; xt = 1:14; xtl = 1:14; tol = 2.5;
    pos = [A.channel];
    ttl = 'Channel Graph - 2.4 GHz';
  end
  if ~isempty(A)
    ok = ~isnan(pos); A = A(ok); pos = pos(ok);
  end

  pal = [1.00 0.40 0.40;  0.20 1.00 0.45;  0.65 0.45 1.00;  1.00 0.75 0.20; ...
         0.30 0.80 1.00;  1.00 0.50 0.90;  0.80 0.90 0.30];
  chs = unique(pos);

  fig = figure('Color', [0.08 0.08 0.08], 'Name', ttl, 'NumberTitle', 'off', ...
               'InvertHardcopy', 'off');                          % saved PNG keeps the dark colours
  ax = axes('Parent', fig); hold(ax, 'on');
  set(ax, 'Color', 'k', 'XColor', 'w', 'YColor', 'w', 'GridColor', [0.45 0.45 0.45], ...
          'Box', 'on', 'FontSize', 9);

  % arches: weakest first so the strongest ends up on top
  [~, ord] = sort([A.rssi_dbm], 'ascend');
  for k = ord
    c = pos(k);
    col = pal(mod(find(chs == c, 1) - 1, size(pal, 1)) + 1, :);
    r = min(max(A(k).rssi_dbm, FLOOR + 1), TOP);
    xs = linspace(c - half, c + half, 120);
    ys = FLOOR + (r - FLOOR) * (1 - ((xs - c) / half).^2);
    fill([xs xs(end) xs(1)], [ys FLOOR FLOOR], col, 'FaceAlpha', 0.35, ...
         'EdgeColor', col, 'LineWidth', 1.4, 'Parent', ax);
  end

  % labels: strongest first; push a label down if it would sit on top of an earlier one
  lx = []; ly = [];
  [~, ord] = sort([A.rssi_dbm], 'descend');
  for k = ord
    c = pos(k);
    col = pal(mod(find(chs == c, 1) - 1, size(pal, 1)) + 1, :);
    y = min(max(A(k).rssi_dbm, FLOOR + 1), TOP) + 1.2;
    while any(abs(lx - c) < tol & abs(ly - y) < 3.2) && y > FLOOR + 4
      y = y - 3.2;
    end
    lx(end+1) = c; ly(end+1) = y;                                  %#ok<AGROW>
    name = A(k).ssid;
    if strcmp(name, '<hidden>'), name = 'HiddenSSID'; end
    text(c, y, sprintf('%s (~%.0fm)', name, A(k).dist_m), 'Color', col, 'FontSize', 8, ...
         'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
         'Interpreter', 'none', 'Parent', ax);
  end

  xlim(ax, xl); ylim(ax, [FLOOR TOP]);
  set(ax, 'XTick', xt, 'XTickLabel', arrayfun(@num2str, xtl, 'UniformOutput', false), ...
          'YTick', FLOOR:10:TOP);
  if is5, set(ax, 'XTickLabelRotation', 90); end
  grid(ax, 'on');
  xlabel(ax, 'Channel', 'Color', 'w'); ylabel(ax, 'Signal strength (dBm)', 'Color', 'w');
  title(ax, ttl, 'Color', 'w');
  hold(ax, 'off');
  if nargin >= 3 && ~isempty(png_path)
    saveas(fig, png_path);
    fprintf('Saved graph: %s\n', png_path);
  end
end
