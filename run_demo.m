% RUN_DEMO  Try the whole project in one go - no radio hardware needed.
%
%   Open MATLAB (or GNU Octave) in this folder and type:   run_demo
%
%   Step 1  self-test of the 802.11a/g (OFDM) receiver on 7 real recordings (expects 121 / 121 frames)
%   Step 2  self-test of the 802.11b (DSSS) receiver on 4 test signals
%   Step 3  finds the Wi-Fi networks in a real 0.5 s recording of channel 6 (data/sample_capture_ch6.mat):
%           prints the table (SSID, BSSID, channel, RSSI, distance), draws the channel graph and
%           saves channel_graph_2.4GHz.png in the current folder
%   Step 4  shows the result of a real live scan (data/aps_found.mat): 21 access points

repo_dir = fileparts(mfilename('fullpath'));
addpath(fullfile(repo_dir, 'src'));

fprintf('\n========== Step 1: OFDM receiver self-test (802.11a/g) ==========\n');
wifi_rx_ref;

fprintf('\n========== Step 2: DSSS receiver self-test (802.11b) ==========\n');
wifi_dsss_rx('selftest');

fprintf('\n========== Step 3: find the Wi-Fi networks in a saved recording ==========\n');
aps = ap_from_file(fullfile(repo_dir, 'data', 'sample_capture_ch6.mat'));

fprintf('\n========== Step 4: result of a real live scan (channels 1, 6 and 104) ==========\n');
scan = load(fullfile(repo_dir, 'data', 'aps_found.mat'));
print_ap_table(scan.aps);
plot_channel_graph(scan.aps, '2.4');
plot_channel_graph(scan.aps, '5');
