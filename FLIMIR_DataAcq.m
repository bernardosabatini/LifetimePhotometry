function FLIMIR_DataAcq()
% FLIMIR_DATAACQ  GUI application for FLIM/lifetime imaging data acquisition.
%
%   FLIMIR_DataAcq() launches the data acquisition interface.  Requires
%   MATLAB R2023a+; the National Instruments backend additionally needs the
%   Data Acquisition Toolbox.
%
%   ARCHITECTURE
%
%   Hardware access is isolated behind FlimirDaqDevice.  This file, the
%   calibration routine and the analysis functions contain no vendor calls
%   and no vendor channel names - they ask the device object for both.
%
%     FLIMIR_DataAcq.m ......... GUI, acquisition state machine, plotting
%     calibration.m ............ sweep orchestration, live monitor, plots
%     calculate_phase_calibration.m  mixer phase fit      (pure analysis)
%     calculate_tau_s_g.m ...... per-block lifetime/phasor (pure analysis)
%     flimir_gaussian_lp.m ..... shared filter             (pure maths)
%     flimir_estimate_phasors.m  shared phasor solve       (pure maths)
%     FlimirDaqDevice.m ........ the hardware interface (abstract)
%     FlimirDaqNI.m ............ National Instruments implementation
%     FlimirDaqSimulated.m ..... synthetic signals, no hardware needed
%     flimir_daq_backends.m .... finds the available backends
%
%   To support different hardware - a LabJack, say - write one subclass of
%   FlimirDaqDevice and drop it in this folder.  It appears in the Backend
%   menu automatically; nothing else changes.
%
%   Features:
%     - Select a DAQ backend and a device from those it discovers
%     - Configure 5 analog inputs at user-specified sample rate
%     - Two analog outputs, laser power and phase shifter control, both
%       DC, both driven from 0 at the start of an acquisition and
%       returned to 0 at the end
%     - Digital output for shutter TTL control
%     - Phase shifter sweep calibration in calibration.m
%     - Real-time chart recorder (lifetime + intensity) with selectable
%       rolling (sweep-and-overwrite) or expanding time axis
%     - Extra input channels plotted on their own axes when flagged
%     - Real-time phasor plot (s, g on unit semicircle)
%     - Stream data to binary file (not held in memory)
%     - Configurable extra analog/digital input channels
%     - Per-callback lifetime/phasor computation in calculate_tau_s_g.m
%     - Save/load acquisition settings
%
%   A save directory must be chosen before Setup Acquisition will run;
%   there is deliberately no default.

    %% Create app data structure
    app = struct();
    % The one object that talks to hardware.  Everything below this line
    % goes through the FlimirDaqDevice interface; no vendor calls live in
    % this file.  See flimir_daq_backends for how backends are discovered.
    app.device = [];
    app.backends = flimir_daq_backends();
    app.isRunning = false;
    app.isSetUp = false;
    app.fid = -1;
    app.nSamplesWritten = 0;
    app.startTime = [];
    app.metadataFile = '';
    app.dataFile = '';

    % Chart recorder buffers.  All plotted traces share one x vector and one
    % nTraces-by-nSamples y matrix so that roll/expand bookkeeping is done
    % once regardless of how many extra input channels are being displayed.
    app.chartX = [];         % 1 x nSamples time vector
    app.chartY = [];         % nTraces x nSamples data matrix
    app.chartHandles = gobjects(0);  % line handle per row of chartY

    % Y limits that only ever widen.  MATLAB's own autoscaling retunes the
    % axis on every block, so a trace that wanders makes the whole chart
    % jump around and nothing can be read off it.  These hold the widest
    % range seen so far, per axis, and Reset Range clears them.
    app.yRangeLifetime = [];
    app.yRangeIntensity = [];
    app.yRangeExtra = [];
    app.nSlots = 0;          % slots across the window in rolling mode
    app.sBuffer = [];
    app.gBuffer = [];
    app.callbackCount = 0;

    % Phasor contrail: the newest point is drawn full size in the saturated
    % colour, and older ones shrink and fade toward the pale colour until
    % they drop off the end of the trail.
    app.phasorTrailLength = 150;
    app.phasorNewColor = [0.05 0.30 0.60];
    app.phasorOldColor = [0.78 0.86 0.94];
    app.phasorNewSize = 36;
    app.phasorOldSize = 6;
    app.phasorMinAlpha = 0.12;
    app.currentTime = 0;   % seconds since acquisition start
    app.blockPeriod = 0.1; % seconds of data per acquisition callback

    % Extra input channels
    app.extraPlotFlags = [];
    app.extraPlotNames = {};
    app.extraColumns = [];   % data-matrix column for each plotted extra channel

    % Mixer phase calibration.  Empty until a calibration sweep has run;
    % without it calculate_tau_s_g cannot resolve a phasor angle and the
    % lifetime/phasor displays stay blank.
    app.mixerCalibration = [];
    app.darkCalibration = [];   % offsets measured with the laser blocked

    % Five FLIM inputs until Setup says otherwise.  The raw monitor sizes
    % itself from this and is built before Setup ever runs.
    app.nInputChannels = 5;
    app.channelNames = {};

    % --- detector -----------------------------------------------------
    app.detector = [];          % FlimirDetector, or empty for 'none'
    app.detectorPowered = false;

    % --- raw channel monitor ------------------------------------------
    % An optional second chart recorder showing the acquired inputs
    % themselves, sharing the main chart's buffers so it sweeps and
    % erases in step with it rather than keeping its own clock.
    app.rawFig = [];
    app.rawAx = [];
    app.rawLines = gobjects(0);
    app.rawY = [];              % nRawTraces x nSamples, same columns as chartY
    app.rawRange = {};          % ratcheted y limits, as the main chart has
    app.calibrationFile = '';   % file the current calibration came from
    app.settingsFile = '';      % settings file this session is tied to
    app.storedWindows = struct();  % window geometry from the settings file
    app.phaseMonitorColumn = [];   % data column carrying the phase loopback

    %% Build GUI
    app.fig = uifigure('Name', 'FLIMIR Data Acquisition', ...
        'Position', [100 100 1200 750], ...
        'CloseRequestFcn', @(~,~) closeFigure());

    % Two tabs: the one you watch during a run, and the one you set up
    % beforehand.  Everything that configures the rig lives on Settings,
    % so the Acquisition tab holds only what is touched while recording.
    app.tabGroup = uitabgroup(app.fig, 'Units', 'normalized', ...
        'Position', [0 0 1 1]);
    acqTab = uitab(app.tabGroup, 'Title', 'Acquisition');
    setTab = uitab(app.tabGroup, 'Title', 'Settings');

    % --- Acquisition tab: run controls beside the plots ---
    acqGrid = uigridlayout(acqTab, [1, 2]);
    acqGrid.ColumnWidth = {210, '1x'};
    runPanel = uipanel(acqGrid, 'Title', 'Run');
    runPanel.Layout.Row = 1;
    runPanel.Layout.Column = 1;

    % --- Settings tab: the configuration column and the calibration column ---
    settingsGrid = uigridlayout(setTab, [1, 2]);
    settingsGrid.ColumnWidth = {'1.15x', '1x'};

    %% Settings tab, left column - acquisition configuration
    leftPanel = uipanel(settingsGrid, 'Title', 'Acquisition Settings');
    leftPanel.Layout.Row = 1;
    leftPanel.Layout.Column = 1;

    %% Settings tab, right column - calibration
    % The calibration actions and everything they produce, in one place:
    % the numbers below are as much a part of the configuration as the
    % controls on the left, and they are the ones you cannot type in.
    calibPanel = uipanel(settingsGrid, 'Title', 'Calibration');
    calibPanel.Layout.Row = 1;
    calibPanel.Layout.Column = 2;
    calibOuterGrid = uigridlayout(calibPanel, [3, 1]);
    calibOuterGrid.RowHeight = {34, 26, '1x'};

    calibActionPanel = uipanel(calibOuterGrid, 'BorderType', 'none');
    calibActionPanel.Layout.Row = 1;

    app.calibRefreshBtn = uibutton(calibOuterGrid, ...
        'Text', 'Refresh values', ...
        'Tooltip', ['Re-read the current calibration and detector ' ...
                    'settings into the summary below.'], ...
        'ButtonPushedFcn', @(~,~) refreshSettingsSummary());
    app.calibRefreshBtn.Layout.Row = 2;

    % Read-only: these are measured, not entered
    app.settingsSummary = uitextarea(calibOuterGrid, 'Editable', 'off', ...
        'FontName', 'Consolas', 'Value', {''});
    app.settingsSummary.Layout.Row = 3;

    leftGrid = uigridlayout(leftPanel, [17, 2]);
    leftGrid.RowHeight = repmat({30}, 1, 17);
    leftGrid.RowHeight{12} = '1x';  % extra channels table gets remaining space
    leftGrid.ColumnWidth = {115, '1x'};  % fixed label column, rest to controls

    % Every child below gets an explicit Layout.Row/Layout.Column. Relying on
    % auto-placement breaks as soon as a component spans both columns, which
    % is what previously pushed the extra-channels table into a 30 px row.

    % --- DAQ Backend (row 1) ---
    placeInGrid(uilabel(leftGrid, 'Text', 'DAQ Backend:'), 1, 1);
    app.backendDropdown = uidropdown(leftGrid, ...
        'Items', backendNames(), 'ItemsData', backendClasses(), ...
        'Tooltip', ['Which hardware interface to talk to. Any ' ...
                    'FlimirDaqDevice subclass on the path appears here.'], ...
        'ValueChangedFcn', @(~,~) backendChanged());
    placeInGrid(app.backendDropdown, 1, 2);

    % --- Device Selection (row 2, spans both columns so the full device
    %     description stays readable) ---
    deviceGrid = uigridlayout(leftGrid, [1, 3]);
    placeInGrid(deviceGrid, 2, [1 2]);
    deviceGrid.Padding = [0 0 0 0];
    deviceGrid.ColumnSpacing = 4;
    deviceGrid.ColumnWidth = {65, '1x', 44};
    uilabel(deviceGrid, 'Text', 'Device:');
    app.deviceDropdown = uidropdown(deviceGrid, 'Items', {'(none)'}, ...
        'Value', '(none)', ...
        'ValueChangedFcn', @(~,~) deviceChanged());
    scanBtn = uibutton(deviceGrid, 'Text', 'Scan', ...
        'Tooltip', 'Rescan for devices on the selected backend', ...
        'ButtonPushedFcn', @(~,~) refreshDevices());

    % --- Sample Rate (row 2) ---
    placeInGrid(uilabel(leftGrid, 'Text', 'Sample Rate (Hz):'), 3, 1);
    app.sampleRateSpinner = uispinner(leftGrid, 'Value', 1000, ...
        'Limits', [1 100000], 'Step', 100, ...
        'ValueChangedFcn', @(~,~) invalidateSetup());
    placeInGrid(app.sampleRateSpinner, 3, 2);

    % --- Laser Power + Phase Shifter (row 3), the two analog outputs ---
    placeInGrid(uilabel(leftGrid, 'Text', 'Laser Power (V):'), 4, 1);
    aoGrid = uigridlayout(leftGrid, [1, 5]);
    placeInGrid(aoGrid, 4, 2);
    aoGrid.Padding = [0 0 0 0];
    aoGrid.ColumnSpacing = 4;
    aoGrid.ColumnWidth = {56, 54, 62, 68, '1x'};

    app.laserPowerSpinner = uispinner(aoGrid, 'Value', 0, ...
        'Limits', [0 5], 'Step', 0.1, 'ValueDisplayFormat', '%.1f', ...
        'Tooltip', ['Requested laser power, 0 to 5. What reaches ao0 ' ...
                    'depends on the invert setting below. Held during a ' ...
                    'calibration sweep and through a run, and returned ' ...
                    'to the off level at the end of either. Can be ' ...
                    'changed while running.'], ...
        'ValueChangedFcn', @(~,~) applyOutputLevels());
    app.laserPowerSpinner.Layout.Column = 1;

    % Manual benchtop control, independent of a run.  Aligning the lamp
    % to a sample should not require starting an acquisition.
    app.laserToggle = uibutton(aoGrid, 'state', 'Text', 'Laser', ...
        'Value', false, ...
        'Tooltip', ['Drive the laser output now, outside a run. Has no ' ...
                    'effect on what calibration or acquisition do - ' ...
                    'they take the output over and switch it off ' ...
                    'afterwards. Changing the power while this is on ' ...
                    'updates the output immediately.'], ...
        'ValueChangedFcn', @(~,~) laserToggleChanged());
    app.laserToggle.Layout.Column = 2;

    uilabel(aoGrid, 'Text', 'Phase (V):', 'HorizontalAlignment', 'right');

    app.phaseShifterSpinner = uispinner(aoGrid, 'Value', 0, ...
        'Limits', [0 10], 'Step', 0.1, 'ValueDisplayFormat', '%.2f', ...
        'Tooltip', ['Phase shifter DC control level on ao1. Held for the ' ...
                    'duration of the acquisition and returned to 0 V at ' ...
                    'the end. Can be changed while running. Use ' ...
                    'Calibration to map volts to phase.'], ...
        'ValueChangedFcn', @(~,~) applyOutputLevels());

    % --- Phase monitor loopback (row 5) ---
    % --- Detector (row 5) ---
    % The PMT is powered from here rather than from its own vendor GUI, so
    % the high voltage can be brought up and down around each calibration
    % and each run without anybody having to remember.  That matters more
    % than convenience: enabling the head shifts the DC channel by about
    % 100 mV on this rig, so an offset measured with the HV off does not
    % describe the data taken with it on.  Everything - dark calibration,
    % phase sweep, acquisition - therefore runs at the one HV setting
    % chosen here.
    placeInGrid(uilabel(leftGrid, 'Text', 'Detector:'), 5, 1);
    detGrid = uigridlayout(leftGrid, [1, 6]);
    placeInGrid(detGrid, 5, 2);
    detGrid.Padding = [0 0 0 0];
    detGrid.ColumnSpacing = 4;
    detGrid.ColumnWidth = {'1x', '1.1x', 44, 48, 60, 20};

    app.detectorDropdown = uidropdown(detGrid, ...
        'Items', {'None', 'Thorlabs PMT2100'}, ...
        'ItemsData', {'none', 'thorlabsPMT2100'}, ...
        'Value', 'none', ...
        'Tooltip', ['Detector to power automatically. "None" leaves ' ...
                    'the detector alone, for a rig whose PMT is ' ...
                    'switched by hand or not present.'], ...
        'ValueChangedFcn', @(~,~) detectorSelectionChanged());
    app.detectorDropdown.Layout.Row = 1;
    app.detectorDropdown.Layout.Column = 1;

    % Which physical head, picked from what is actually on the USB bus
    app.detectorDeviceDropdown = uidropdown(detGrid, ...
        'Items', {'(scan for devices)'}, 'ItemsData', {''}, ...
        'Enable', 'off', ...
        'Tooltip', 'Serial number of the detector head to drive.', ...
        'ValueChangedFcn', @(~,~) refreshSettingsSummary());
    app.detectorDeviceDropdown.Layout.Row = 1;
    app.detectorDeviceDropdown.Layout.Column = 2;

    app.detectorScanBtn = uibutton(detGrid, 'Text', 'Scan', ...
        'Enable', 'off', ...
        'Tooltip', 'Re-scan USB for attached detector heads.', ...
        'ButtonPushedFcn', @(~,~) scanDetectorDevices(true));
    app.detectorScanBtn.Layout.Row = 1;
    app.detectorScanBtn.Layout.Column = 3;

    hvLabel = uilabel(detGrid, 'Text', 'HV (%)', ...
        'HorizontalAlignment', 'right');
    hvLabel.Layout.Row = 1;
    hvLabel.Layout.Column = 4;

    app.detectorHVSpinner = uispinner(detGrid, ...
        'Limits', [0 100], 'Value', 10, 'Step', 5, ...
        'ValueDisplayFormat', '%.0f', ...
        'Tooltip', ['Gain control setting, in percent of the head''s ' ...
                    'range. Used for calibration and acquisition alike ' ...
                    '- they have to match or the offsets do not apply.'], ...
        'ValueChangedFcn', @(~,~) detectorHVChanged());
    app.detectorHVSpinner.Layout.Row = 1;
    app.detectorHVSpinner.Layout.Column = 5;

    % Lit whenever the high voltage is actually on
    app.detectorLamp = uilamp(detGrid, 'Color', [0.75 0.75 0.75], ...
        'Tooltip', 'Detector HV is off');
    app.detectorLamp.Layout.Row = 1;
    app.detectorLamp.Layout.Column = 6;

    % Selecting the PMT says which detector is there; linking says the
    % software may switch it.  They are separate on purpose - you can
    % have the head open for status and still drive the HV by hand.
    app.invertLaserCheck = uicheckbox(leftGrid, ...
        'Text', 'Invert laser control (5 V = off, 0 V = max)', ...
        'Value', false, ...
        'Tooltip', ['For a controller whose full-scale input means off. ' ...
                    'The power box stays 0 = off to 5 = max either way; ' ...
                    'only what is driven onto ao0 changes. Everything ' ...
                    'that parks the laser drives the off level, so ' ...
                    '"make safe" stays safe.'], ...
        'ValueChangedFcn', @(~,~) laserInversionChanged());
    placeInGrid(app.invertLaserCheck, 14, [1 2]);

    app.invertIntensityCheck = uicheckbox(leftGrid, ...
        'Text', 'Invert intensity (ai4 x -1, for a negative-going detector)', ...
        'Value', false, ...
        'Tooltip', ['Multiply the DC/intensity channel by -1 as it ' ...
                    'arrives. A PMT front end usually reads more ' ...
                    'negative with more light, and the modulation ' ...
                    'depth divides by the mean DC level, so an ' ...
                    'un-inverted channel biases every lifetime. ' ...
                    'Re-run the dark calibration after changing this.'], ...
        'ValueChangedFcn', @(~,~) intensityInversionChanged());
    placeInGrid(app.invertIntensityCheck, 16, [1 2]);

    app.pmtLinkCheck = uicheckbox(leftGrid, ...
        'Text', 'Link to Thorlabs PMT (auto HV for calibration and acquisition)', ...
        'Value', false, ...
        'Tooltip', ['When ticked, the HV is raised before each ' ...
                    'calibration and each run and lowered afterwards, ' ...
                    'so every measurement is taken at the same ' ...
                    'detector setting. When clear, nothing touches the ' ...
                    'detector automatically.'], ...
        'ValueChangedFcn', @(~,~) refreshSettingsSummary());
    placeInGrid(app.pmtLinkCheck, 15, [1 2]);

    % Wiring the phase shifter output back into a spare analog input lets
    % the calibration use the phase voltage it actually MEASURED, on the
    % same sample clock as the mixer channels, instead of the voltage it
    % believes it commanded.  That removes any output-to-input timing
    % offset from the result, and reports what that offset was.
    placeInGrid(uilabel(leftGrid, 'Text', 'Phase Monitor:'), 6, 1);
    pmGrid = uigridlayout(leftGrid, [1, 2]);
    placeInGrid(pmGrid, 6, 2);
    pmGrid.Padding = [0 0 0 0];
    pmGrid.ColumnSpacing = 4;
    pmGrid.ColumnWidth = {62, '1x'};

    app.phaseMonitorCheck = uicheckbox(pmGrid, 'Text', 'Use', ...
        'Value', false, ...
        'Tooltip', ['Record the phase shifter output on a spare analog ' ...
                    'input. The calibration then uses the measured phase ' ...
                    'voltage rather than the commanded one, and reports ' ...
                    'the output-to-input lag it finds.'], ...
        'ValueChangedFcn', @(~,~) invalidateSetup());

    app.phaseMonitorEdit = uieditfield(pmGrid, 'Value', '', ...
        'Placeholder', '(analog input wired to the phase output)', ...
        'Tooltip', 'Analog input the phase shifter output is looped into', ...
        'ValueChangedFcn', @(~,~) invalidateSetup());

    % --- Display Window + Update Interval (rows 6-7) ---
    placeInGrid(uilabel(leftGrid, 'Text', 'Window (s):'), 7, 1);
    dispGrid = uigridlayout(leftGrid, [1, 3]);
    placeInGrid(dispGrid, 7, 2);
    dispGrid.Padding = [0 0 0 0];
    dispGrid.ColumnSpacing = 4;
    dispGrid.ColumnWidth = {62, 68, '1x'};

    app.rollingWindowSpinner = uispinner(dispGrid, 'Value', 5, ...
        'Limits', [1 3600], 'Step', 5, ...
        'Tooltip', 'Width of the displayed time axis', ...
        'ValueChangedFcn', @(~,~) windowSizeChanged());

    uilabel(dispGrid, 'Text', 'Update (s):', 'HorizontalAlignment', 'right');

    app.updateIntervalSpinner = uispinner(dispGrid, 'Value', 0.1, ...
        'Limits', [0.01 10], 'Step', 0.05, ...
        'ValueDisplayFormat', '%.2f', ...
        'Tooltip', ['How often the acquisition callback runs and the ' ...
                    'display refreshes. Also sets how much data is ' ...
                    'processed per point on the chart recorder.'], ...
        'ValueChangedFcn', @(~,~) updateIntervalChanged());

    app.rollingWindowCheck = uicheckbox(leftGrid, ...
        'Text', 'Rolling window (sweep back to left)', ...
        'Value', true, ...
        'Tooltip', ['On: the time axis stays fixed at the window width and ' ...
                    'the trace restarts at the left edge when it reaches ' ...
                    'the right. Off: the time axis keeps expanding, ' ...
                    'compressing the data to fit.'], ...
        'ValueChangedFcn', @(~,~) rollingModeChanged());
    placeInGrid(app.rollingWindowCheck, 8, [1 2]);

    % --- Save Directory (row 6) ---
    placeInGrid(uilabel(leftGrid, 'Text', 'Save Directory:'), 9, 1);
    saveDirGrid = uigridlayout(leftGrid, [1, 2]);
    placeInGrid(saveDirGrid, 9, 2);
    saveDirGrid.Padding = [0 0 0 0];
    saveDirGrid.ColumnSpacing = 4;
    saveDirGrid.ColumnWidth = {'1x', 60};
    % Deliberately blank at startup - Setup Acquisition refuses to run until
    % the user has picked somewhere for the data to go
    app.saveDirEdit = uieditfield(saveDirGrid, 'Value', '', ...
        'Placeholder', '(none selected)');
    uibutton(saveDirGrid, 'Text', 'Browse', ...
        'ButtonPushedFcn', @(~,~) browseSaveDir());

    % --- Calibration file (row 8) ---
    placeInGrid(uilabel(leftGrid, 'Text', 'Calibration:'), 10, 1);
    calGrid = uigridlayout(leftGrid, [1, 2]);
    placeInGrid(calGrid, 10, 2);
    calGrid.Padding = [0 0 0 0];
    calGrid.ColumnSpacing = 4;
    calGrid.ColumnWidth = {'1x', 60};
    app.calFileEdit = uieditfield(calGrid, 'Value', '', ...
        'Editable', 'off', 'Placeholder', '(none loaded)', ...
        'Tooltip', ['Mixer calibration in use. Every sweep is archived ' ...
                    'automatically; this is the one being applied, and ' ...
                    'it travels with the settings file.']);
    uibutton(calGrid, 'Text', 'Load', ...
        'Tooltip', 'Load a previously saved calibration sweep', ...
        'ButtonPushedFcn', @(~,~) browseCalibrationFile());

    % --- Extra Channels Label + Add Buttons (row 9) ---
    placeInGrid(uilabel(leftGrid, 'Text', 'Extra Channels:'), 11, 1);
    extraBtnGrid = uigridlayout(leftGrid, [1, 3]);
    placeInGrid(extraBtnGrid, 11, 2);
    extraBtnGrid.Padding = [0 0 0 0];
    extraBtnGrid.ColumnSpacing = 4;
    extraBtnGrid.ColumnWidth = {'1x', '1x', '1.4x'};
    addAIBtn = uibutton(extraBtnGrid, 'Text', '+AI', ...
        'Tooltip', 'Add extra analog input', ...
        'ButtonPushedFcn', @(~,~) addExtraChannel('Analog'));
    addDIBtn = uibutton(extraBtnGrid, 'Text', '+DI', ...
        'Tooltip', 'Add extra digital input', ...
        'ButtonPushedFcn', @(~,~) addExtraChannel('Digital'));
    removeChanBtn = uibutton(extraBtnGrid, 'Text', 'Remove', ...
        'Tooltip', 'Remove the selected row(s)', ...
        'ButtonPushedFcn', @(~,~) removeExtraChannel());

    % --- Extra Channels Table (row 8, spans 2 columns, gets the slack) ---
    app.extraChannelsTable = uitable(leftGrid, ...
        'ColumnName', {'Type', 'Channel', 'Plot'}, ...
        'ColumnFormat', {'char', 'char', 'logical'}, ...
        'ColumnEditable', [false, true, true], ...
        'ColumnWidth', {70, 'auto', 45}, ...
        'SelectionType', 'row', ...
        'Tooltip', ['Double-click the Channel cell to edit it. ' ...
                    'Uncheck Plot to record a channel without displaying it.'], ...
        'CellEditCallback', @(~,~) invalidateSetup(), ...
        'Data', cell(0, 3));
    placeInGrid(app.extraChannelsTable, 12, [1 2]);

    % Anything here changes the DAQ configuration, so it invalidates an
    % existing setup and is locked out while an acquisition is running
    app.configControls = {app.deviceDropdown, scanBtn, app.sampleRateSpinner, ...
        app.updateIntervalSpinner, addAIBtn, addDIBtn, removeChanBtn, ...
        app.extraChannelsTable};

    % --- Setup, on both tabs -------------------------------------------
    % Setup is the one configuration action wanted from the run tab too,
    % so there are two buttons driving the same callback.  They are kept
    % in one array and enabled together: a set(...) on the array cannot
    % leave the copies disagreeing the way two separate assignments can.
    settingsSetupBtn = uibutton(leftGrid, 'Text', 'Setup Acquisition', ...
        'BackgroundColor', [0.3 0.6 1], ...
        'ButtonPushedFcn', @(~,~) setupAcquisition());
    placeInGrid(settingsSetupBtn, 13, [1 2]);

    % The three calibration steps share one row, left to right in the
    % order they are meant to be run
    calibBtnGrid = uigridlayout(calibActionPanel, [1, 3]);
    calibBtnGrid.Padding = [0 0 0 0];
    calibBtnGrid.ColumnSpacing = 4;

    app.darkBtn = uibutton(calibBtnGrid, 'Text', 'Dark', ...
        'Enable', 'off', ...
        'Tooltip', ['Dark calibration: measure the channel offsets ' ...
                    'with the laser physically blocked. Do this ' ...
                    'first - its numbers are used by both sweeps and ' ...
                    'by the live lifetime calculation.'], ...
        'ButtonPushedFcn', @(~,~) runDarkCalibration());
    app.darkBtn.Layout.Row = 1;
    app.darkBtn.Layout.Column = 1;

    app.calibBtn = uibutton(calibBtnGrid, 'Text', 'Calibrate', ...
        'Enable', 'off', ...
        'Tooltip', ['Phase shifter sweep at three ramp speeds ' ...
                    '(1, 3, 10 s), compared against each other to ' ...
                    'check the shifter is not rate dependent. The ' ...
                    'slowest usable ramp becomes the calibration.'], ...
        'ButtonPushedFcn', @(~,~) runCalibration('multiscale'));
    app.calibBtn.Layout.Row = 1;
    app.calibBtn.Layout.Column = 2;

    app.avgCalibBtn = uibutton(calibBtnGrid, 'Text', 'Avg Calibrate', ...
        'Enable', 'off', ...
        'Tooltip', ['Phase shifter sweep of ten 1 s ramps, averaged ' ...
                    'into one calibration. Same total time as the ' ...
                    'three-speed sweep but trades the rate-dependence ' ...
                    'check for a lower-variance answer.'], ...
        'ButtonPushedFcn', @(~,~) runCalibration('averaged'));
    app.avgCalibBtn.Layout.Row = 1;
    app.avgCalibBtn.Layout.Column = 3;

    % --- Run controls, on the Acquisition tab --------------------------
    runGrid = uigridlayout(runPanel, [6, 1]);
    runGrid.RowHeight = {34, 34, 34, 28, 28, '1x'};

    runSetupBtn = uibutton(runGrid, 'Text', 'Setup Acquisition', ...
        'BackgroundColor', [0.3 0.6 1], ...
        'ButtonPushedFcn', @(~,~) setupAcquisition());
    runSetupBtn.Layout.Row = 1;

    app.setupBtn = [settingsSetupBtn, runSetupBtn];

    app.startBtn = uibutton(runGrid, 'Text', 'Start Acquisition', ...
        'BackgroundColor', [0.2 0.8 0.2], ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) startAcquisition());
    app.startBtn.Layout.Row = 2;

    app.endBtn = uibutton(runGrid, 'Text', 'End Acquisition', ...
        'BackgroundColor', [1 0.3 0.3], ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) endAcquisition());
    app.endBtn.Layout.Row = 3;

    % Detector state, where it can be seen during a run
    detStatusGrid = uigridlayout(runGrid, [1, 2]);
    detStatusGrid.Layout.Row = 4;
    detStatusGrid.Padding = [0 0 0 0];
    detStatusGrid.ColumnWidth = {'1x', 22};
    app.detectorStatusLabel = uilabel(detStatusGrid, 'Text', 'Detector: off');
    app.detectorStatusLabel.Layout.Column = 1;
    app.runLamp = uilamp(detStatusGrid, 'Color', [0.75 0.75 0.75]);
    app.runLamp.Layout.Column = 2;

    % What the run will actually compute, given the calibration state
    app.modeLabel = uilabel(runGrid, 'Text', '', 'FontAngle', 'italic', ...
        'WordWrap', 'on');
    app.modeLabel.Layout.Row = 5;

    % --- Settings file buttons -----------------------------------------
    settingsBtnGrid = uigridlayout(leftGrid, [1, 2]);
    placeInGrid(settingsBtnGrid, 17, [1 2]);
    settingsBtnGrid.Padding = [0 0 0 0];
    settingsBtnGrid.ColumnWidth = {'1x', '1x'};
    uibutton(settingsBtnGrid, 'Text', 'Save Settings', ...
        'ButtonPushedFcn', @(~,~) saveSettings());
    uibutton(settingsBtnGrid, 'Text', 'Load Settings', ...
        'ButtonPushedFcn', @(~,~) loadSettings());

    %% Acquisition tab, right column - Plots
    rightPanel = uipanel(acqGrid, 'Title', 'Data Display');
    rightPanel.Layout.Row = 1;
    rightPanel.Layout.Column = 2;
    rightGrid = uigridlayout(rightPanel, [2, 1]);
    rightGrid.RowHeight = {'1x', '1x'};
    app.rightGrid = rightGrid;

    % Both time-domain axes live in one panel and are positioned by hand in
    % normalized units.  Setting Position pins the *inner* (plot box) extent,
    % so giving them the same left edge and width makes their x-axes line up
    % exactly - a grid layout would not, because each axes reserves its own
    % width for y tick labels.
    timePanel = uipanel(rightGrid, 'BorderType', 'none', ...
        'AutoResizeChildren', 'off');  % keep our hand-set axes positions
    timePanel.Layout.Row = 1;
    app.timePanel = timePanel;

    % Chart recorder axes
    app.chartAx = uiaxes(timePanel, 'Units', 'normalized', ...
        'PositionConstraint', 'innerposition');
    title(app.chartAx, 'Chart Recorder');
    xlabel(app.chartAx, 'Time (s)');
    yyaxis(app.chartAx, 'left');
    ylabel(app.chartAx, 'Lifetime (ns)');
    app.chartAx.YColor = [0 0.4 0.8];
    yyaxis(app.chartAx, 'right');
    ylabel(app.chartAx, 'Intensity (VDC)');
    app.chartAx.YColor = [0.8 0.2 0];

    % Chart recorder traces.  Plain line objects (not animatedline) because
    % rolling mode overwrites samples in place rather than only appending.
    yyaxis(app.chartAx, 'left');
    app.lifetimeLine = line(app.chartAx, NaN, NaN, ...
        'Color', [0 0.4 0.8], 'LineWidth', 1.5, 'LineStyle', '-');
    yyaxis(app.chartAx, 'right');
    app.intensityLine = line(app.chartAx, NaN, NaN, ...
        'Color', [0.8 0.2 0], 'LineWidth', 1.5, 'LineStyle', '-');

    % S and G are not plotted against time: the phasor plot below already
    % shows where the sample sits, and a second view of the same two
    % numbers was redundant.

    % Reset Range sits with the axes it acts on rather than over in the
    % controls panel.  A uibutton is always in pixels, and timePanel has
    % AutoResizeChildren off, so it goes inside a borderless panel that
    % can take normalized units and carry it through a window resize -
    % the same approach as the add-channel overlay below.
    % Sized to read as controls rather than chart furniture: the first
    % version was small, pale and tucked against the panel edge, and got
    % mistaken for part of the plot.
    resetHolder = uipanel(timePanel, 'BorderType', 'none', ...
        'Units', 'normalized', 'Position', [0.545 0.925 0.40 0.075]);
    resetGrid = uigridlayout(resetHolder, [1, 2]);
    resetGrid.Padding = [0 0 0 0];
    resetGrid.ColumnSpacing = 6;
    app.rawChanBtn = uibutton(resetGrid, 'Text', 'Raw Channels', ...
        'FontSize', 12, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.30 0.55 0.85], 'FontColor', [1 1 1], ...
        'Tooltip', ['Open a second chart recorder showing the acquired ' ...
                    'inputs themselves. It shares this chart''s buffers, ' ...
                    'so it sweeps and erases in step with it.'], ...
        'ButtonPushedFcn', @(~,~) showRawChannelWindow());
    app.rawChanBtn.Layout.Row = 1;
    app.rawChanBtn.Layout.Column = 1;
    app.resetRangeBtn = uibutton(resetGrid, 'Text', 'Reset Range', ...
        'FontSize', 12, ...
        'Tooltip', ['Re-fit the y axes to the data currently on screen. ' ...
                    'They only widen on their own, so this is the only ' ...
                    'way they get smaller.'], ...
        'ButtonPushedFcn', @(~,~) resetChartRange());
    app.resetRangeBtn.Layout.Row = 1;
    app.resetRangeBtn.Layout.Column = 2;

    % Extra input channels axes - shares the chart recorder's time axis and
    % is hidden outright (not just collapsed) when nothing is plotted on it
    app.extraAx = uiaxes(timePanel, 'Units', 'normalized', ...
        'PositionConstraint', 'innerposition');
    title(app.extraAx, 'Extra Inputs');
    xlabel(app.extraAx, 'Time (s)');
    ylabel(app.extraAx, 'Value');
    app.extraLines = gobjects(0);

    % Phasor plot axes
    app.phasorAx = uiaxes(rightGrid);
    app.phasorAx.Layout.Row = 2;
    title(app.phasorAx, 'Phasor Plot');
    xlabel(app.phasorAx, 'G');
    ylabel(app.phasorAx, 'S');
    hold(app.phasorAx, 'on');
    app.phasorAx.DataAspectRatio = [1 1 1];
    app.phasorAx.XLim = [-0.05 1.05];
    app.phasorAx.YLim = [-0.05 0.55];

    % Draw unit semicircle on phasor plot
    theta = linspace(0, pi, 200);
    semicircleG = 0.5 + 0.5 * cos(theta);
    semicircleS = 0.5 * sin(theta);
    plot(app.phasorAx, semicircleG, semicircleS, 'k-', 'LineWidth', 1);

    % Scatter for phasor data points.  Per-point CData, SizeData and
    % AlphaData give each marker its own colour, size and transparency,
    % which is what produces the contrail; 'flat' alpha makes the scatter
    % read AlphaData per point instead of applying one value to all.
    app.phasorScatter = scatter(app.phasorAx, NaN, NaN, ...
        app.phasorNewSize, app.phasorNewColor, 'filled', ...
        'MarkerEdgeColor', 'none', ...
        'MarkerFaceAlpha', 'flat', ...
        'AlphaDataMapping', 'none');

    %% Add-channel prompt, as an overlay inside the main window
    % A separate uifigure would be a real OS window: opening and closing one
    % makes the app blink and hands focus back to the MATLAB desktop, so the
    % prompt is drawn as a panel on top of the layout instead.
    % Normalized units keep it centred and proportional across figure
    % resizes without needing a SizeChangedFcn (which would not fire while
    % the figure auto-resizes its children anyway).
    app.chanDlg = uipanel(app.fig, 'Visible', 'off', ...
        'BorderType', 'line', 'BackgroundColor', [0.94 0.94 0.96], ...
        'Units', 'normalized', 'Position', [0.35 0.385 0.30 0.23]);

    chanGrid = uigridlayout(app.chanDlg, [4, 2]);
    chanGrid.RowHeight = {22, '1x', 25, 28};
    chanGrid.ColumnWidth = {'1x', '1x'};

    app.chanDlgTitle = uilabel(chanGrid, 'Text', '', 'FontWeight', 'bold');
    placeInGrid(app.chanDlgTitle, 1, [1 2]);

    app.chanDlgPrompt = uilabel(chanGrid, 'Text', '', ...
        'WordWrap', 'on', 'VerticalAlignment', 'top');
    placeInGrid(app.chanDlgPrompt, 2, [1 2]);

    app.chanDlgEdit = uieditfield(chanGrid, 'Value', '');
    placeInGrid(app.chanDlgEdit, 3, [1 2]);

    chanOkBtn = uibutton(chanGrid, 'Text', 'OK', ...
        'ButtonPushedFcn', @(~,~) commitChannelDialog());
    placeInGrid(chanOkBtn, 4, 1);

    chanCancelBtn = uibutton(chanGrid, 'Text', 'Cancel', ...
        'ButtonPushedFcn', @(~,~) hideChannelDialog());
    placeInGrid(chanCancelBtn, 4, 2);

    app.pendingChannelType = '';

    % Apply the initial time-axis mode and do an initial device scan
    rebuildChartTraces();
    refreshTimeAxis();
    refreshDevices();

    % Everything is built, so the session can now be bound to a settings
    % file - and set itself up from it when that file is complete.
    %
    % Synchronously, after forcing a draw.  The draw is what puts the
    % window on screen before the modal file dialog appears over it; an
    % earlier version used a timer for that, which left the app
    % interactive while the settings were still being applied, so a fast
    % click could call Setup while the settings load was releasing the
    % device out from under it.
    drawnow;
    startupSettingsFile();

    %% ====================== NESTED FUNCTIONS ======================

    function names = backendNames()
        if isempty(app.backends)
            names = {'(no backends found)'};
        else
            names = {app.backends.name};
        end
    end

    function classes = backendClasses()
        if isempty(app.backends)
            classes = {''};
        else
            classes = {app.backends.class};
        end
    end

    function backendChanged()
        % A different backend means a different device list and different
        % channel names, so tear down and start over
        releaseDevice();
        invalidateSetup();
        refreshDevices();
    end

    function dev = currentDevice()
        % The device object for the selected backend + device id, created
        % lazily and reused.  Empty when nothing valid is selected.
        dev = [];
        className = app.backendDropdown.Value;
        deviceID = app.deviceDropdown.Value;
        if isempty(className) || isempty(deviceID) || ...
                contains(string(deviceID), "(")
            return;
        end
        if ~isempty(app.device) && isvalid(app.device) && ...
                strcmp(class(app.device), className) && ...
                strcmp(app.device.DeviceID, deviceID)
            dev = app.device;
            return;
        end
        releaseDevice();
        app.device = feval(className, deviceID);
        dev = app.device;
        adoptKnownCalibration(dev);
    end

    function adoptKnownCalibration(dev)
        % Some devices know their own mixer calibration - the simulator
        % does, because it generated the data in the first place.  Adopt
        % it so lifetime and phasor work without first running a sweep
        % that could only rediscover what was put in.  Real hardware
        % returns empty here and is unaffected.
        try
            mc = dev.knownCalibration();
        catch
            return;
        end
        if isempty(mc)
            return;
        end
        app.mixerCalibration = mc;
        if isfield(mc, 'source')
            setCalibrationFile(sprintf('(%s)', mc.source));
        else
            setCalibrationFile('(supplied by the device)');
        end
    end

    function releaseDevice()
        if ~isempty(app.device) && isvalid(app.device)
            try
                app.device.closeDevice();
            catch
            end
            delete(app.device);
        end
        app.device = [];
    end

    function refreshDevices()
        try
            className = app.backendDropdown.Value;
            if isempty(className)
                app.deviceDropdown.Items = {'(no backends found)'};
                app.deviceDropdown.Value = '(no backends found)';
                return;
            end
            devices = feval([className '.listDevices']);
            releaseDevice();
            if isempty(devices)
                app.deviceDropdown.Items = {'(no devices found)'};
                app.deviceDropdown.Value = '(no devices found)';
            else
                deviceIDs = string({devices.id});
                descriptions = string({devices.description});
                displayItems = strings(size(deviceIDs));
                for i = 1:numel(deviceIDs)
                    displayItems(i) = sprintf('%s (%s)', deviceIDs(i), descriptions(i));
                end
                app.deviceDropdown.Items = displayItems;
                app.deviceDropdown.ItemsData = deviceIDs;
                app.deviceDropdown.Value = deviceIDs(1);
            end
            updateDeviceTooltip();
        catch ME
            app.deviceDropdown.Items = {'(device scan failed)'};
            app.deviceDropdown.Value = '(device scan failed)';
            uialert(app.fig, sprintf('Error scanning devices:\n%s', ME.message), ...
                'Device Scan Error');
        end
    end

    function deviceChanged()
        updateDeviceTooltip();
        invalidateSetup();
    end

    function updateIntervalChanged()
        % The callback period sets both the DAQ batch size and the spacing
        % of points on the chart recorder, so the buffers are rebuilt
        app.blockPeriod = app.updateIntervalSpinner.Value;
        resetChartBuffers();
        refreshTimeAxis();
        invalidateSetup();
    end

    function invalidateSetup()
        % Called when a control that defines the DAQ configuration changes.
        % The existing DataAcquisition objects no longer match what the UI
        % says, so they are torn down and Setup has to run again.
        if app.isRunning || ~app.isSetUp
            return;
        end
        cleanupDAQ();
        app.isSetUp = false;
        set(app.setupBtn, 'Enable', 'on');
        app.startBtn.Enable = 'off';
        app.endBtn.Enable = 'off';
        app.calibBtn.Enable = 'off';
    end

    function v = laserVoltsFor(power)
        % Requested power (0..5) -> the volts to put on ao0.
        %
        % The power control keeps one meaning - 0 is off, 5 is maximum -
        % whichever way the hardware wants it.  Only this mapping moves.
        % Every caller goes through here, including the ones that park
        % the output, because on an inverted controller "off" is full
        % scale and writing a literal 0 would mean full power.
        lim = app.laserPowerSpinner.Limits;
        if app.invertLaserCheck.Value
            v = lim(2) - power;
        else
            v = power;
        end
    end

    function v = laserOffVolts()
        v = laserVoltsFor(0);
    end

    function laserInversionChanged()
        % Tell the device what "off" now means before anything else can
        % park the output, then re-assert the current state so the
        % hardware is never left at the old convention's level.
        if ~isempty(app.device) && isvalid(app.device)
            app.device.LaserOffVolts = laserOffVolts();
        end
        applyOutputLevels();
        if ~app.isRunning && ~app.laserToggle.Value
            parkLaser();
        end
        refreshSettingsSummary();
    end

    function laserToggleChanged()
        % Manual on/off, only meaningful when nothing else owns the
        % output.  A run or a calibration drives the laser itself and
        % switches it off afterwards.
        if app.isRunning
            app.laserToggle.Value = false;
            return;
        end
        if isempty(app.device) || ~isvalid(app.device)
            app.laserToggle.Value = false;
            uialert(app.fig, ['Run Setup Acquisition first - the output ' ...
                'session has to exist before the laser can be driven.'], ...
                'No Output Session');
            return;
        end
        try
            if app.laserToggle.Value
                app.device.writeOutputs(laserVoltsFor(app.laserPowerSpinner.Value), ...
                    app.phaseShifterSpinner.Value, true);
            else
                parkLaser();
            end
        catch ME
            app.laserToggle.Value = false;
            uialert(app.fig, sprintf('Could not drive the laser:\n%s', ...
                ME.message), 'Laser Error');
        end
        updateLaserToggleLook();
    end

    function parkLaser()
        if isempty(app.device) || ~isvalid(app.device)
            return;
        end
        try
            app.device.writeOutputs(laserOffVolts(), ...
                app.phaseShifterSpinner.Value, false);
        catch
        end
    end

    function releaseLaserToggle()
        % Anything that takes the laser over - a run, a sweep, a dark
        % measurement - owns it until it finishes and parks it.  Clear
        % the manual toggle so the button never claims the laser is on
        % while the output has been switched off underneath it.
        if isfield(app, 'laserToggle') && isvalid(app.laserToggle)
            app.laserToggle.Value = false;
            updateLaserToggleLook();
        end
    end

    function updateLaserToggleLook()
        if ~isfield(app, 'laserToggle') || ~isvalid(app.laserToggle)
            return;
        end
        if app.laserToggle.Value
            app.laserToggle.BackgroundColor = [0.95 0.75 0.2];
            app.laserToggle.Text = 'Laser ON';
        else
            app.laserToggle.BackgroundColor = [0.94 0.94 0.94];
            app.laserToggle.Text = 'Laser';
        end
    end

    function applyOutputLevels()
        % Push the two DC analog output levels to the hardware.  Both are
        % live controls: changing either one retargets the output
        % immediately rather than waiting for the next run - during a
        % run, and also while the manual laser toggle is holding the
        % output on, which is the whole point of that toggle.
        app.laserPower = app.laserPowerSpinner.Value;
        app.phaseVolts = app.phaseShifterSpinner.Value;
        if isempty(app.device) || ~isvalid(app.device)
            return;
        end
        live = app.isRunning || app.laserToggle.Value;
        if ~live
            return;
        end
        try
            app.device.writeOutputs(laserVoltsFor(app.laserPower), ...
                app.phaseVolts, true);
        catch ME
            fprintf('Could not update analog outputs: %s\n', ME.message);
        end
    end

    function setCalibButtonState()
        % Calibration needs a set-up device that can generate a
        % hardware-clocked sweep.  A backend that cannot say so up front
        % gets the button disabled with the reason on the tooltip, rather
        % than an error 47 seconds in.
        if ~app.isSetUp || isempty(app.device) || ~isvalid(app.device)
            app.calibBtn.Enable = 'off';
            app.avgCalibBtn.Enable = 'off';
            app.darkBtn.Enable = 'off';
            return;
        end

        % The dark measurement is a clocked read with the outputs held at
        % 0 V, so it rides on the same capability the sweep needs
        if ~app.device.supportsClockedSweep()
            app.darkBtn.Enable = 'off';
            app.darkBtn.Tooltip = ['Needs a hardware-clocked read, ' ...
                'which this backend does not provide.'];
        elseif isempty(app.darkCalibration)
            app.darkBtn.Enable = 'on';
            app.darkBtn.Tooltip = ['Not yet measured. Offsets are ' ...
                'assumed zero until this is run.'];
        else
            app.darkBtn.Enable = 'on';
            app.darkBtn.Tooltip = sprintf(['Last measured %s%s. ' ...
                'Re-run whenever the optics or electronics change.'], ...
                app.darkCalibration.timestamp, ...
                stabilitySuffix(app.darkCalibration));
        end
        if ~app.device.supportsClockedSweep()
            app.calibBtn.Enable = 'off';
            app.avgCalibBtn.Enable = 'off';
            app.calibBtn.Tooltip = sprintf(['The %s backend cannot ' ...
                'generate a hardware-clocked sweep, so calibration is ' ...
                'unavailable for it. Load a calibration from file ' ...
                'instead.'], feval([class(app.device) '.backendName']));
            return;
        end
        app.calibBtn.Enable = 'on';
        app.avgCalibBtn.Enable = 'on';
    end

    function setConfigEnabled(tf)
        % Lock the configuration controls for the duration of a run
        if tf
            state = 'on';
        else
            state = 'off';
        end
        for i = 1:numel(app.configControls)
            app.configControls{i}.Enable = state;
        end
    end

    function updateDeviceTooltip()
        % Long device descriptions still truncate in the dropdown, so keep
        % the full text available on hover
        items = string(app.deviceDropdown.Items);
        idx = find(string(app.deviceDropdown.ItemsData) == ...
            string(app.deviceDropdown.Value), 1);
        if isempty(idx) || isempty(items)
            app.deviceDropdown.Tooltip = '';
        else
            app.deviceDropdown.Tooltip = char(items(idx));
        end
    end

    function placeInGrid(component, row, col)
        % Pin a component to an explicit cell of its uigridlayout parent
        component.Layout.Row = row;
        component.Layout.Column = col;
    end

    function updateTimeLimits()
        % Limits only - called on every acquisition callback, so it stays
        % cheap and leaves the axis labels alone
        windowSize = app.rollingWindowSpinner.Value;
        if app.rollingWindowCheck.Value
            xl = [0, windowSize];
        else
            xl = [0, max(windowSize, app.currentTime)];
        end
        app.chartAx.XLim = xl;
        app.extraAx.XLim = xl;
    end

    function refreshTimeAxis()
        % Update the time-axis limits and labels for the current mode and
        % window width, without disturbing the plotted data.  Only the
        % bottom-most time plot carries the x label - they share an axis.
        if app.rollingWindowCheck.Value
            xLabelTxt = 'Time in sweep (s)';
        else
            xLabelTxt = 'Time (s)';
        end
        stack = timeAxesStack();
        for i = 1:numel(stack)
            if i == numel(stack)
                xlabel(stack(i), xLabelTxt);
            else
                xlabel(stack(i), '');
            end
        end
        updateTimeLimits();
    end

    function stack = timeAxesStack()
        % The time plots, top to bottom.  The chart recorder is always
        % shown; extra inputs only when in use.
        stack = app.chartAx;
        if ~isempty(app.extraLines)
            stack(end+1) = app.extraAx;
        end
    end

    function layoutTimeAxes()
        % Position the time-domain axes.  All get the same left edge and
        % width so their x-axes are in register, and only the bottom one
        % keeps its tick labels.
        % InnerPosition is the plot box itself.  Position/OuterPosition
        % would NOT line up: the chart recorder reserves room on the right
        % for its second y-axis and the others do not, so the same outer
        % box yields different right edges.
        axLeft = 0.14;
        axWidth = 0.79;
        bottomMargin = 0.11;
        topMargin = 0.095;   % room for the chart's own buttons above
        gap = 0.055;

        stack = timeAxesStack();
        n = numel(stack);
        available = 1 - bottomMargin - topMargin - (n - 1) * gap;
        axHeight = available / n;

        for i = 1:n
            ax = stack(i);
            % index 1 is the top plot, so count rows from the bottom
            rowFromBottom = n - i;
            y = bottomMargin + rowFromBottom * (axHeight + gap);
            ax.PositionConstraint = 'innerposition';
            ax.InnerPosition = [axLeft y axWidth axHeight];
            ax.Visible = 'on';
            ax.Toolbar.Visible = 'on';
            if i == n
                ax.XTickLabelMode = 'auto';
            else
                ax.XTickLabel = {};
            end
        end

        if isempty(app.extraLines)
            % Park the unused axes outside the panel so that neither it nor
            % its hover toolbar leaves anything behind next to the chart
            app.extraAx.Visible = 'off';
            app.extraAx.Toolbar.Visible = 'off';
            app.extraAx.PositionConstraint = 'innerposition';
            app.extraAx.InnerPosition = [axLeft -1.2 axWidth 0.3];
            app.rightGrid.RowHeight = {'1x', '1x'};
        else
            app.rightGrid.RowHeight = {'1.9x', '1x'};
        end
    end

    function resizeSweepBuffer()
        % Rolling mode keeps one slot per acquisition block across the
        % window.  Growing or shrinking the window reallocates the buffer,
        % carrying over whatever slots still exist so the trace survives.
        if ~app.rollingWindowCheck.Value
            return;
        end
        newSlots = max(2, round(app.rollingWindowSpinner.Value / app.blockPeriod));
        if newSlots == app.nSlots
            return;
        end
        nTraces = size(app.chartY, 1);
        newY = nan(nTraces, newSlots);
        nCopy = min(app.nSlots, newSlots);
        if nCopy > 0 && nTraces > 0
            newY(:, 1:nCopy) = app.chartY(:, 1:nCopy);
        end
        app.nSlots = newSlots;
        app.chartY = newY;
        app.chartX = (0:newSlots-1) * app.blockPeriod;
        redrawChart();
    end

    function windowSizeChanged()
        resizeSweepBuffer();
        refreshTimeAxis();
    end

    function rollingModeChanged()
        % The x coordinates mean different things in the two modes, so the
        % buffer is rebuilt from scratch and the trace restarts
        resetChartBuffers();
        refreshTimeAxis();
    end

    function resetChartBuffers()
        % (Re)allocate the shared chart buffers for the current mode and the
        % current number of traces, and blank every plotted line
        nTraces = numel(app.chartHandles);
        if app.rollingWindowCheck.Value
            app.nSlots = max(2, round(app.rollingWindowSpinner.Value / app.blockPeriod));
            app.chartX = (0:app.nSlots-1) * app.blockPeriod;
            app.chartY = nan(nTraces, app.nSlots);
            app.rawY = nan(rawTraceCount(), app.nSlots);
        else
            app.nSlots = 0;
            app.chartX = [];
            app.chartY = nan(nTraces, 0);
            app.rawY = nan(rawTraceCount(), 0);
        end
        redrawChart();
        redrawRawChart();
    end

    function redrawChart()
        % Push the shared buffers out to the individual line objects
        if isempty(app.chartX)
            for i = 1:numel(app.chartHandles)
                set(app.chartHandles(i), 'XData', NaN, 'YData', NaN);
            end
            return;
        end
        for i = 1:numel(app.chartHandles)
            set(app.chartHandles(i), 'XData', app.chartX, 'YData', app.chartY(i, :));
        end
        applyRatchetedYLimits();
    end

    function applyRatchetedYLimits()
        % Widen the y axes to fit the data, never narrow them.
        %
        % Traces 1 and 2 are lifetime and intensity, on the chart
        % recorder's left and right axes; anything after that is an extra
        % input and shares one axis of its own.  Each group keeps the
        % widest range it has ever needed, so the chart stops rescaling
        % underneath the user as values wander.
        n = size(app.chartY, 1);
        if n >= 1
            app.yRangeLifetime = widenRange(app.yRangeLifetime, app.chartY(1, :));
            setAxisRange(app.chartAx, 'left', app.yRangeLifetime);
        end
        if n >= 2
            app.yRangeIntensity = widenRange(app.yRangeIntensity, app.chartY(2, :));
            setAxisRange(app.chartAx, 'right', app.yRangeIntensity);
        end
        if n >= 3 && ~isempty(app.extraLines)
            app.yRangeExtra = widenRange(app.yRangeExtra, app.chartY(3:end, :));
            setAxisRange(app.extraAx, '', app.yRangeExtra);
        end
        % yyaxis leaves whichever side it touched last as the active one;
        % put it back so anything drawn later lands on the left as before
        yyaxis(app.chartAx, 'left');
    end

    function setAxisRange(ax, side, range)
        if isempty(range) || ~isvalid(ax)
            return;
        end
        if ~isempty(side)
            yyaxis(ax, side);
        end
        ax.YLim = range;
    end

    function range = widenRange(range, data)
        % Union of the range so far with what the data needs, padded so a
        % trace never sits exactly on the frame.
        data = data(isfinite(data));
        if numel(data) < 2
            % One sample has no range, and the placeholder window we would
            % invent for it would then be locked in by the ratchet.  Wait
            % for something real instead.
            return;
        end
        lo = min(data(:));
        hi = max(data(:));
        span = hi - lo;
        if span <= 0
            % A genuinely flat trace still needs a window to be visible in
            pad = max(abs(hi) * 0.05, 0.5);
        else
            pad = span * 0.05;
        end
        needed = [lo - pad, hi + pad];
        if isempty(range)
            range = needed;
        else
            range = [min(range(1), needed(1)), max(range(2), needed(2))];
        end
    end

    % =====================================================================
    % Raw channel monitor
    %
    % A second chart recorder for the acquired inputs themselves.  It
    % deliberately owns no timing of its own: it writes into a buffer
    % with the same columns as chartY, filled from the same callback and
    % cleared by the same reset, so it sweeps, wraps and erases exactly
    % in step with the lifetime chart no matter how the window or the
    % rolling mode is changed.
    % =====================================================================

    function showRawChannelWindow()
        if ~isempty(app.rawFig) && isvalid(app.rawFig)
            figure(app.rawFig);
            return;
        end
        buildRawChannelWindow();
        redrawRawChart();
    end

    function buildRawChannelWindow()
        % One row per channel, stacked and sharing the time axis.  A
        % single axes made the four mixer channels unreadable: they sit
        % on different offsets and swing by different amounts, so one
        % ratcheted range is set by whichever channel is largest and
        % flattens the rest.  A row each gives every channel its own
        % scale while the time base stays common.
        names = rawChannelNames();
        n = numel(names);
        app.rawFig = figure('Name', 'Raw Input Channels', ...
            'NumberTitle', 'off', 'Color', 'w', ...
            'Position', [120 90 820 680], ...
            'Tag', 'FLIMIR_RawChannelMonitor', ...
            'CloseRequestFcn', @(src,~) closeRawChannelWindow(src));

        % Reopen where the settings file left it, if that is still on screen
        if isfield(app, 'storedWindows') && isfield(app.storedWindows, 'rawChannels')
            p = sanitiseWindowPosition(app.storedWindows.rawChannels);
            if ~isempty(p)
                app.rawFig.Position = p;
            end
        end

        colors = lines(n);
        app.rawAx = gobjects(1, n);
        app.rawLines = gobjects(1, n);
        app.rawRange = cell(1, n);

        left = 0.11;
        width = 0.86;
        bottom = 0.085;
        top = 0.035;
        gap = 0.012;
        h = (1 - bottom - top - (n - 1) * gap) / n;

        for k = 1:n
            % Row 1 at the top, so count up from the bottom
            y = bottom + (n - k) * (h + gap);
            ax = axes(app.rawFig, 'Position', [left y width h]);
            app.rawLines(k) = plot(ax, NaN, NaN, ...
                'Color', colors(k, :), 'LineWidth', 1.2);
            ylabel(ax, names{k});
            grid(ax, 'on');
            box(ax, 'on');
            if k == n
                xlabel(ax, 'Time (s)');
            else
                ax.XTickLabel = {};
            end
            app.rawAx(k) = ax;
        end
        title(app.rawAx(1), 'Raw input channels (V)');

        uicontrol(app.rawFig, 'Style', 'pushbutton', 'String', 'Reset Range', ...
            'Units', 'normalized', 'Position', [0.86 0.005 0.13 0.045], ...
            'Callback', @(~,~) resetRawRange());
    end

    function closeRawChannelWindow(src)
        delete(src);
        app.rawFig = [];
        app.rawAx = gobjects(0);
        app.rawLines = gobjects(0);
    end

    function tf = rawWindowOpen()
        tf = ~isempty(app.rawFig) && isvalid(app.rawFig);
    end

    function names = rawChannelNames()
        % The five FLIM inputs, named as the device spells them
        names = app.channelNames(1:min(5, numel(app.channelNames)));
        if isempty(names)
            names = {'ai0','ai1','ai2','ai3','ai4'};
        end
    end

    function n = rawTraceCount()
        n = min(5, max(1, app.nInputChannels));
    end

    function redrawRawChart()
        if ~rawWindowOpen() || isempty(app.rawY)
            return;
        end
        n = min(numel(app.rawLines), size(app.rawY, 1));
        if numel(app.rawRange) < n
            app.rawRange(end+1:n) = {[]};
        end
        xl = app.chartAx.XLim;
        for k = 1:n
            set(app.rawLines(k), 'XData', app.chartX, 'YData', app.rawY(k, :));
            % Each row ratchets on its own data, same rule as the chart
            app.rawRange{k} = widenRange(app.rawRange{k}, app.rawY(k, :));
            if ~isempty(app.rawRange{k})
                app.rawAx(k).YLim = app.rawRange{k};
            end
            % Same x window as the main chart, by construction
            app.rawAx(k).XLim = xl;
        end
    end

    function resetRawRange()
        app.rawRange = cell(1, numel(app.rawLines));
        redrawRawChart();
        drawnow limitrate;
    end

    function resetChartRange()
        % Forget the accumulated ranges and re-fit to what is on screen
        % now.  The only way the axes ever get smaller.
        app.yRangeLifetime = [];
        app.yRangeIntensity = [];
        app.yRangeExtra = [];
        applyRatchetedYLimits();
        drawnow limitrate;
    end

    function appendChartSample(values, rawValues)
        % Add one sample per trace.  In rolling mode the sample overwrites
        % the slot for its position in the sweep and a short run of NaNs is
        % punched in just ahead of it, giving the erase bar that wipes the
        % previous sweep as the new one fills in.  In expanding mode the
        % sample is appended and the axis grows.
        %
        % rawValues, if given, is the matching sample for the raw channel
        % monitor.  It is written here rather than in its own routine so
        % the sweep position and the erase bar are computed exactly once:
        % two windows sharing one pen cannot drift apart.
        values = values(:);
        if isempty(values)
            return;
        end
        if nargin < 2
            rawValues = [];
        end
        rawValues = rawValues(:);

        if app.rollingWindowCheck.Value
            if app.nSlots < 2 || size(app.chartY, 2) ~= app.nSlots
                resetChartBuffers();
            end
            idx = mod(app.callbackCount - 1, app.nSlots) + 1;
            app.chartY(:, idx) = values;

            % Erase bar: a small gap of NaNs immediately ahead of the pen,
            % wide enough to stay visible even on a short window
            eraseLen = min(app.nSlots - 1, max(2, round(0.02 * app.nSlots)));
            eraseIdx = mod(idx - 1 + (1:eraseLen), app.nSlots) + 1;
            app.chartY(:, eraseIdx) = NaN;

            if ~isempty(rawValues) && size(app.rawY, 2) == app.nSlots
                n = min(numel(rawValues), size(app.rawY, 1));
                app.rawY(1:n, idx) = rawValues(1:n);
                app.rawY(:, eraseIdx) = NaN;
            end
        else
            app.chartX(end+1) = app.currentTime;
            app.chartY(:, end+1) = values;
            if ~isempty(rawValues)
                n = min(numel(rawValues), size(app.rawY, 1));
                col = nan(size(app.rawY, 1), 1);
                col(1:n) = rawValues(1:n);
                app.rawY(:, end+1) = col;
            end
        end

        redrawChart();
        redrawRawChart();
    end

    function resetPhasorTrail()
        % Clear the trail.  All four data properties have to be set in one
        % call: setting them one at a time would momentarily leave CData or
        % AlphaData a different length from XData, which errors.
        app.sBuffer = [];
        app.gBuffer = [];
        set(app.phasorScatter, 'XData', NaN, 'YData', NaN, ...
            'CData', app.phasorNewColor, 'SizeData', app.phasorNewSize, ...
            'AlphaData', 1);
    end

    function updatePhasorTrail()
        n = numel(app.gBuffer);
        if n == 0
            resetPhasorTrail();
            return;
        end

        % age runs 0 (oldest point still in the trail) to 1 (newest)
        if n == 1
            age = 1;
        else
            age = linspace(0, 1, n)';
        end

        % Squaring the alpha ramp keeps the tail faint while the head stays
        % crisp, so the trail reads as a direction rather than a cloud
        alphaData = app.phasorMinAlpha + (1 - app.phasorMinAlpha) * age.^2;
        sizeData = app.phasorOldSize + ...
            (app.phasorNewSize - app.phasorOldSize) * age.^2;
        cData = app.phasorOldColor + ...
            (app.phasorNewColor - app.phasorOldColor) .* age;

        set(app.phasorScatter, 'XData', app.gBuffer, 'YData', app.sBuffer, ...
            'CData', cData, 'SizeData', sizeData, 'AlphaData', alphaData);
    end

    function rebuildChartTraces()
        % Rebuild the list of plotted traces (lifetime, intensity, then any
        % extra input channels flagged for plotting) and show or hide the
        % extra-inputs axes to match.
        delete(app.extraLines(isgraphics(app.extraLines)));
        app.extraLines = gobjects(0);

        names = app.extraPlotNames;
        nExtra = numel(names);
        if nExtra > 0
            colors = lines(nExtra);
            for i = 1:nExtra
                app.extraLines(i) = line(app.extraAx, NaN, NaN, ...
                    'Color', colors(i, :), 'LineWidth', 1.2, ...
                    'DisplayName', names{i});
            end
            % Legend must sit inside the axes: an 'outside' location would
            % shrink the plot box and break the x-axis alignment
            legend(app.extraAx, 'show', 'Location', 'northeast');
        else
            legend(app.extraAx, 'off');
        end

        layoutTimeAxes();
        refreshTimeAxis();
        % Trace order must match the values vector the callback builds:
        % lifetime, intensity, then each plotted extra channel
        app.chartHandles = [app.lifetimeLine, app.intensityLine, ...
            app.extraLines];
        % Different channels mean the accumulated extra-input range is
        % about something else now, so start it over
        app.yRangeExtra = [];

        % The raw monitor labels its traces with the device's channel
        % names, so it has to be rebuilt when those change
        if rawWindowOpen()
            delete(app.rawFig);
            app.rawRange = {};
            buildRawChannelWindow();
        end
        resetChartBuffers();
    end

    function browseSaveDir()
        startDir = app.saveDirEdit.Value;
        if isempty(startDir) || ~isfolder(startDir)
            startDir = pwd;
        end
        folder = uigetdir(startDir, 'Select Save Directory');
        focusAppWindow();
        if ischar(folder) && ~isequal(folder, 0)
            app.saveDirEdit.Value = folder;
        end
    end

    function addExtraChannel(channelType)
        % Open the in-window prompt.  Nothing is added until OK is pressed;
        % commitChannelDialog finishes the job.
        currentData = app.extraChannelsTable.Data;
        app.pendingChannelType = channelType;

        % Channel names are the backend's vocabulary, so both the wording
        % and the suggestion come from the device
        reserved = reservedChannels();
        if strcmp(channelType, 'Analog')
            app.chanDlgTitle.Text = 'Add Analog Input';
            app.chanDlgPrompt.Text = sprintf( ...
                'Analog input channel to add (%s are already in use):', ...
                strjoin(reserved, ', '));
        else
            app.chanDlgTitle.Text = 'Add Digital Input';
            app.chanDlgPrompt.Text = sprintf( ...
                'Digital input line to add (%s is reserved for the shutter):', ...
                shutterChannelName());
        end

        app.chanDlgEdit.Value = nextAvailableChannel(channelType, currentData);
        app.chanDlg.Visible = 'on';
        focus(app.chanDlgEdit);
    end

    function hideChannelDialog()
        app.chanDlg.Visible = 'off';
        app.pendingChannelType = '';
    end

    function commitChannelDialog()
        chID = strtrim(app.chanDlgEdit.Value);
        channelType = app.pendingChannelType;
        hideChannelDialog();
        if isempty(chID) || isempty(channelType)
            return;
        end

        % Reject duplicates and channels already used by the fixed hardware
        currentData = app.extraChannelsTable.Data;
        if any(strcmpi(chID, reservedChannels())) || ...
                (~isempty(currentData) && any(strcmpi(chID, currentData(:, 2))))
            uialert(app.fig, sprintf('Channel "%s" is already in use.', chID), ...
                'Duplicate Channel');
            return;
        end

        newRow = {channelType, chID, true};
        if isempty(currentData)
            app.extraChannelsTable.Data = newRow;
        else
            app.extraChannelsTable.Data = [currentData; newRow];
        end

        % Make the new row visible and selected so it is obvious what was added
        newRowIdx = size(app.extraChannelsTable.Data, 1);
        app.extraChannelsTable.Selection = newRowIdx;
        scroll(app.extraChannelsTable, 'bottom');
        invalidateSetup();
    end

    function browseCalibrationFile()
        startDir = strtrim(app.saveDirEdit.Value);
        if isempty(startDir) || ~isfolder(startDir)
            startDir = pwd;
        end
        [fileName, pathName] = uigetfile( ...
            {'*_phase_calibration.mat;*.mat', 'Calibration files (*.mat)'}, ...
            'Load Calibration', startDir);
        focusAppWindow();
        if isequal(fileName, 0)
            return;
        end
        applyCalibrationFile(fullfile(pathName, fileName), true);
    end

    function ok = applyCalibrationFile(filePath, announce)
        % Adopt a calibration from disk.  Returns false and leaves the
        % current one alone if the file is unreadable or holds nothing
        % usable, so a stale path in a settings file cannot silently
        % disarm the lifetime computation.
        ok = false;
        if nargin < 2
            announce = false;
        end
        try
            [mc, ~, summary] = flimir_load_calibration(filePath);
        catch ME
            uialert(app.fig, sprintf('Could not load calibration:\n%s', ...
                ME.message), 'Calibration Load Error');
            return;
        end
        if isempty(mc)
            uialert(app.fig, sprintf(['That file contains no usable mixer ' ...
                'calibration, so the current one is unchanged.\n\n%s'], ...
                summary), 'No Usable Calibration');
            return;
        end

        app.mixerCalibration = mc;
        setCalibrationFile(filePath);
        ok = true;
        if announce
            uialert(app.fig, sprintf(['Calibration loaded.\n\n%s\n\n' ...
                'Lifetime and phasor will be computed from it.'], summary), ...
                'Calibration Loaded', 'Icon', 'success');
        end
    end

    function setCalibrationFile(filePath)
        app.calibrationFile = char(string(filePath));
        app.calFileEdit.Value = app.calibrationFile;
        if isempty(app.calibrationFile)
            app.calFileEdit.Tooltip = 'No calibration loaded.';
        else
            app.calFileEdit.Tooltip = app.calibrationFile;
        end
    end

    function focusAppWindow()
        % Native file/folder pickers hand focus to the MATLAB desktop when
        % they close; pull it back to the acquisition window
        try
            figure(app.fig);
        catch
            % non-fatal - focus is cosmetic
        end
    end

    function ids = reservedChannels()
        % Channels the fixed configuration consumes, named by the backend
        dev = currentDevice();
        if isempty(dev)
            ids = {};
        else
            ids = dev.reservedChannels();
        end
    end

    function id = shutterChannelName()
        dev = currentDevice();
        if isempty(dev)
            id = 'the shutter line';
        else
            id = dev.shutterOutputChannel();
        end
    end

    function chID = nextAvailableChannel(channelType, currentData)
        % Suggest the lowest free channel, in the backend's naming
        if isempty(currentData)
            used = {};
        else
            used = currentData(:, 2);
        end
        dev = currentDevice();
        if ~isempty(dev)
            chID = dev.suggestExtraChannel(channelType, used);
            return;
        end
        used = used(:);

        if strcmp(channelType, 'Analog')
            fmt = 'ai%d';
            startIdx = 5;
        else
            fmt = 'port0/line%d';
            startIdx = 1;
        end
        for k = startIdx:64
            chID = sprintf(fmt, k);
            if ~any(strcmpi(chID, used))
                return;
            end
        end
        chID = sprintf(fmt, startIdx);
    end

    function removeExtraChannel()
        currentData = app.extraChannelsTable.Data;
        if isempty(currentData)
            return;
        end

        % Remove the selected row(s); fall back to the last row if nothing
        % is selected, matching the previous behaviour
        rowsToRemove = app.extraChannelsTable.Selection;
        if isempty(rowsToRemove)
            rowsToRemove = size(currentData, 1);
        end
        rowsToRemove = unique(rowsToRemove(:));

        keep = true(size(currentData, 1), 1);
        keep(rowsToRemove) = false;
        app.extraChannelsTable.Data = currentData(keep, :);
        app.extraChannelsTable.Selection = [];
        invalidateSetup();
    end

    function setupAcquisition()
        try
            % Release any previous session
            cleanupDAQ();

            dev = currentDevice();
            % An invalid handle is not empty, and the startup settings
            % load can release the device between the call above and
            % its use here, so check for both.
            if isempty(dev) || ~isvalid(dev)
                uialert(app.fig, 'Select a valid device before setting up.', ...
                    'Setup Error');
                return;
            end
            deviceID = dev.DeviceID;
            % Require an explicit save directory - there is no default.  If
            % none has been picked yet, put the folder chooser up straight
            % away and carry on with whatever comes back.
            saveDir = strtrim(app.saveDirEdit.Value);
            if isempty(saveDir)
                browseSaveDir();
                saveDir = strtrim(app.saveDirEdit.Value);
            end
            if isempty(saveDir)
                uialert(app.fig, ...
                    ['No save directory selected. Choose where the data and ' ...
                     'metadata files should be written before setting up.'], ...
                    'Save Directory Required');
                return;
            end
            if ~isfolder(saveDir)
                uialert(app.fig, sprintf(['Save directory does not exist:' ...
                    '\n%s\n\nChoose an existing folder.'], saveDir), ...
                    'Save Directory Required');
                return;
            end
            app.saveDirEdit.Value = saveDir;

            app.deviceID = deviceID;
            app.sampleRate = app.sampleRateSpinner.Value;

            % --- Build the channel list the device should acquire --------
            % The first five are the FLIM channels: four mixers then DC.
            % extraColumns records which column of the acquired matrix each
            % plotted extra channel lands in.
            defaults = dev.defaultInputChannels(5);
            channels = struct('id', {}, 'type', {});
            app.channelNames = {};
            app.channelTypes = {};
            for i = 1:numel(defaults)
                channels(end+1) = struct('id', defaults{i}, 'type', 'Analog'); %#ok<AGROW>
                app.channelNames{end+1} = defaults{i};
                app.channelTypes{end+1} = 'AnalogInput';
            end

            extraData = app.extraChannelsTable.Data;
            app.extraPlotFlags = [];
            app.extraColumns = [];
            app.extraPlotNames = {};
            for i = 1:size(extraData, 1)
                chType = extraData{i, 1};
                chID = strtrim(extraData{i, 2});
                plotFlag = logical(extraData{i, 3});
                if isempty(chID)
                    error('Extra channel row %d has a blank channel name.', i);
                end
                channels(end+1) = struct('id', chID, 'type', chType); %#ok<AGROW>
                if strcmp(chType, 'Analog')
                    app.channelTypes{end+1} = 'AnalogInput';
                else
                    app.channelTypes{end+1} = 'DigitalInput';
                end
                app.channelNames{end+1} = chID;
                app.extraPlotFlags(end+1) = plotFlag;
                if plotFlag
                    app.extraColumns(end+1) = numel(channels);
                    app.extraPlotNames{end+1} = chID;
                end
            end

            % Phase monitor loopback, if wired.  It is acquired like any
            % other input but has a role rather than being a user "extra":
            % the calibration reads the phase voltage from this column.
            app.phaseMonitorColumn = [];
            if app.phaseMonitorCheck.Value
                pmID = strtrim(app.phaseMonitorEdit.Value);
                if isempty(pmID)
                    pmID = dev.suggestExtraChannel('Analog', {channels.id});
                    app.phaseMonitorEdit.Value = pmID;
                end
                if any(strcmpi(pmID, {channels.id}))
                    error(['The phase monitor channel "%s" is already in ' ...
                        'use. Pick a spare analog input.'], pmID);
                end
                channels(end+1) = struct('id', pmID, 'type', 'Analog');
                app.channelNames{end+1} = pmID;
                app.channelTypes{end+1} = 'AnalogInput';
                app.phaseMonitorColumn = numel(channels);
            end

            app.nInputChannels = numel(channels);
            app.inputChannels = channels;

            % Callback batch size from the update interval
            app.updateInterval = app.updateIntervalSpinner.Value;
            samplesPerCallback = max(1, round(app.sampleRate * app.updateInterval));

            dev.openInput(channels, app.sampleRate, samplesPerCallback, ...
                @(blockData) dataCallback(blockData));

            % Software-timed outputs: laser level, phase shifter level and
            % the shutter line.  openOutputs parks them all at 0/closed, so
            % the hardware is in a known state between setup and Start.
            dev.openOutputs();

            % Tell the device what "off" means before anything can park
            % the outputs, since an inverted control makes that non-zero
            dev.LaserOffVolts = laserOffVolts();

            % The detector is claimed here, alongside the DAQ, so a rig
            % that cannot open it fails at Setup rather than part-way
            % into a calibration.  It stays powered down until something
            % actually needs it.
            if ~openDetector()
                return;
            end

            app.isSetUp = true;

            % File names are generated per run in startAcquisition, so
            % repeated Start/End cycles never overwrite each other

            % Update button states
            set(app.setupBtn, 'Enable', 'off');
            app.startBtn.Enable = 'on';
            app.endBtn.Enable = 'off';
            setCalibButtonState();

            % Rebuild plot traces for the new channel list and clear them
            app.currentTime = 0;
            app.callbackCount = 0;
            app.blockPeriod = samplesPerCallback / app.sampleRate;
            rebuildChartTraces();
            refreshTimeAxis();
            resetPhasorTrail();

            nPlotted = numel(app.extraPlotNames);
            if isempty(app.mixerCalibration)
                calNote = sprintf(['\n\nNo mixer calibration loaded, so ' ...
                    'lifetime and phasor\nwill not be computed. Run ' ...
                    'Calibration first.']);
                calIcon = 'warning';
            else
                calNote = sprintf('\nCalibration: %s', ...
                    app.mixerCalibration.timestamp);
                calIcon = 'success';
            end
            uialert(app.fig, sprintf(['Setup complete.\nDevice: %s\n' ...
                'Channels: %d inputs (%d extra, %d plotted)\n' ...
                'Rate: %d Hz, update every %.2f s\nSaving to: %s%s'], ...
                deviceID, app.nInputChannels, numel(app.extraPlotFlags), ...
                nPlotted, app.sampleRate, app.blockPeriod, ...
                app.saveDirEdit.Value, calNote), ...
                'Setup Complete', 'Icon', calIcon);

        catch ME
            % Where it failed, to the console: the dialog carries the
            % message but a setup failure is usually a wiring or state
            % problem and the line number is what identifies it
            fprintf('Setup failed: %s\n', ME.message);
            for f = 1:numel(ME.stack)
                fprintf('    %s (line %d)\n', ME.stack(f).name, ME.stack(f).line);
            end
            uialert(app.fig, sprintf('Setup failed:\n%s', ME.message), ...
                'Setup Error');
            app.isSetUp = false;
            set(app.setupBtn, 'Enable', 'on');
            app.startBtn.Enable = 'off';
        end
    end

    function [dataFile, metaFile] = nextRunFiles(saveDir)
        % Timestamps only resolve to the second, so two runs started in
        % quick succession would otherwise write to the same file
        stamp = datestr(now, 'yyyy-mm-dd_HH-MM-SS'); %#ok<TNOW1,DATST>
        base = stamp;
        n = 1;
        while isfile(fullfile(saveDir, sprintf('%s_data.bin', base)))
            n = n + 1;
            base = sprintf('%s_%02d', stamp, n);
        end
        dataFile = fullfile(saveDir, sprintf('%s_data.bin', base));
        metaFile = fullfile(saveDir, sprintf('%s_metadata.mat', base));
    end

    function startAcquisition()
        if ~app.isSetUp || isempty(app.device) || ~isvalid(app.device)
            uialert(app.fig, 'Please run Setup first.', 'Start Error');
            return;
        end

        try
            % Each run gets its own timestamped pair of files, so Start can
            % be pressed repeatedly after End without clobbering earlier runs
            saveDir = strtrim(app.saveDirEdit.Value);
            if isempty(saveDir) || ~isfolder(saveDir)
                uialert(app.fig, ['Select an existing save directory before ' ...
                    'starting.'], 'Save Directory Required');
                return;
            end
            [app.dataFile, app.metadataFile] = nextRunFiles(saveDir);

            % Both analog output levels are read now rather than at setup,
            % so they can be adjusted between runs without reconfiguring
            app.laserPower = app.laserPowerSpinner.Value;
            app.phaseVolts = app.phaseShifterSpinner.Value;

            % Open binary file for writing
            app.fid = fopen(app.dataFile, 'w');
            if app.fid == -1
                uialert(app.fig, sprintf('Cannot open file:\n%s', app.dataFile), ...
                    'File Error');
                return;
            end

            % Reset counters and buffers
            app.nSamplesWritten = 0;
            app.callbackCount = 0;
            app.currentTime = 0;

            % Clear chart traces and phasor points (resetPhasorTrail also
            % empties sBuffer/gBuffer)
            resetChartBuffers();
            refreshTimeAxis();
            resetPhasorTrail();

            app.startTime = datetime('now');

            % Save initial metadata
            metadata = struct();
            metadata.sampleRate = app.sampleRate;
            metadata.nInputChannels = app.nInputChannels;
            metadata.channelNames = app.channelNames;
            metadata.channelTypes = app.channelTypes;
            metadata.laserPower = app.laserPower;
            metadata.phaseShifterV = app.phaseVolts;
            metadata.mixerCalibration = app.mixerCalibration;
            metadata.invertIntensity = logical(app.invertIntensityCheck.Value);
            metadata.updateInterval = app.blockPeriod;
            metadata.startTime = char(app.startTime);
            metadata.dataFile = app.dataFile;
            metadata.bytesPerSample = 8; % double precision
            metadata.dataLayout = 'interleaved'; % [ch1_s1, ch2_s1, ..., chN_s1, ch1_s2, ...]
            save(app.metadataFile, '-struct', 'metadata');

            % The run owns the laser from here
            releaseLaserToggle();
            app.laserToggle.Enable = 'off';

            % Bring the detector up before the outputs, so the HV has
            % settled by the time any light can reach it
            if ~setDetectorPower(true)
                fclose(app.fid);
                app.fid = -1;
                return;
            end

            % Bring the outputs up: laser to power, phase shifter to its DC
            % level, shutter open.  Immediately before the input task starts.
            app.device.writeOutputs(laserVoltsFor(app.laserPower), app.phaseVolts, true);

            % Start continuous background input acquisition
            app.device.startInput();

            app.isRunning = true;
            app.startBtn.Enable = 'off';
            app.endBtn.Enable = 'on';
            set(app.setupBtn, 'Enable', 'off');
            app.calibBtn.Enable = 'off';
            setConfigEnabled(false);

        catch ME
            if app.fid ~= -1
                fclose(app.fid);
                app.fid = -1;
            end
            uialert(app.fig, sprintf('Start failed:\n%s', ME.message), ...
                'Start Error');
        end
    end

    function dataCallback(data)
        % Called by the device backend with each block of samples as an
        % nSamples-by-nChannels matrix.  Nothing here knows what hardware
        % produced it.
        try
            % Put the intensity channel the right way up before anything
            % looks at it - including the file, so what is saved is what
            % was analysed.  The flag is in the metadata, so the raw ADC
            % reading is always recoverable.
            data = flimir_apply_intensity_sign(data, ...
                app.invertIntensityCheck.Value);

            % Write raw data to binary file (channels-fastest layout)
            if app.fid ~= -1
                fwrite(app.fid, data', 'double');
                app.nSamplesWritten = app.nSamplesWritten + size(data, 1);
            end

            % Lifetime and phasor coordinates from the 5 default analog
            % inputs.  Intensity is VDC, the fifth channel: that is the
            % unmodulated fluorescence level, which is what "intensity"
            % means here.  Fall back to the block mean if the DC channel
            % is not present.
            % With no mixer calibration there is nothing to turn the four
            % mixer channels into a lifetime, and running the estimator
            % anyway would draw a confident trace from meaningless
            % constants.  So the run records everything but displays only
            % the intensity, and the lifetime and phasor stay blank.
            nDefault = min(5, size(data, 2));
            if isempty(app.mixerCalibration)
                lt = NaN; s = NaN; g = NaN;
            else
                [lt, s, g] = calculate_tau_s_g(data(:, 1:nDefault), ...
                    app.sampleRate, app.mixerCalibration);
            end
            if nDefault >= 5
                intens = mean(data(:, 5), 'omitnan');
            else
                intens = mean(data(:, 1:nDefault), 'all', 'omitnan');
            end

            % Update callback counter and compute time
            app.callbackCount = app.callbackCount + 1;
            currentTime = app.callbackCount * app.blockPeriod;
            app.currentTime = currentTime;

            % One value per plotted trace, in the order rebuildChartTraces
            % built them: lifetime, intensity, then the block mean of each
            % extra channel flagged for plotting.  S and G are not traced
            % here - they go to the phasor plot.
            values = [lt; intens];
            for k = 1:numel(app.extraColumns)
                col = app.extraColumns(k);
                if col <= size(data, 2)
                    values(end+1, 1) = mean(data(:, col), 'omitnan'); %#ok<AGROW>
                else
                    values(end+1, 1) = NaN; %#ok<AGROW>
                end
            end
            % Block mean of each acquired input, for the raw monitor.
            % Same cadence as everything else on the chart.
            nRaw = min(rawTraceCount(), size(data, 2));
            rawValues = mean(data(:, 1:nRaw), 1, 'omitnan')';

            appendChartSample(values, rawValues);
            updateTimeLimits();

            % Update phasor plot, keeping only the trail's worth of history
            app.sBuffer(end+1) = s;
            app.gBuffer(end+1) = g;
            if numel(app.sBuffer) > app.phasorTrailLength
                app.sBuffer = app.sBuffer(end-app.phasorTrailLength+1:end);
                app.gBuffer = app.gBuffer(end-app.phasorTrailLength+1:end);
            end
            updatePhasorTrail();

            % Force plot update
            drawnow limitrate;

        catch ME
            fprintf('Data callback error: %s\n', ME.message);
        end
    end

    function endAcquisition(quiet)
        if nargin < 1
            quiet = false;
        end
        if ~app.isRunning
            return;
        end

        try
            % Stop input acquisition
            app.device.stopInput();
        catch ME
            fprintf('Error stopping input DAQ: %s\n', ME.message);
        end

        try
            % Close shutter and set laser to 0V via output DAQ
            % Laser to 0 V, phase shifter to 0 V, shutter closed
            app.device.writeOutputs(laserOffVolts(), 0, false);
        catch ME
            fprintf('Error setting outputs: %s\n', ME.message);
        end

        releaseLaserToggle();
        app.laserToggle.Enable = 'on';

        % Light off first, then the detector: the reverse of the start
        % order, so the head is never live with the shutter open
        setDetectorPower(false);

        % Close binary file
        if app.fid ~= -1
            fclose(app.fid);
            app.fid = -1;
        end

        % Update metadata with final info
        try
            endTime = char(datetime('now'));
            nSamplesWritten = app.nSamplesWritten;
            save(app.metadataFile, 'endTime', 'nSamplesWritten', '-append');
        catch ME
            fprintf('Error saving metadata: %s\n', ME.message);
        end

        app.isRunning = false;

        % The DAQ objects are deliberately kept alive and app.isSetUp stays
        % true: the hardware configuration has not changed, so Start can be
        % pressed again straight away.  Any edit to a configuration control
        % calls invalidateSetup and forces a fresh Setup at that point.
        setConfigEnabled(true);
        app.startBtn.Enable = 'on';
        app.endBtn.Enable = 'off';
        set(app.setupBtn, 'Enable', 'on');
        setCalibButtonState();

        if ~quiet
            uialert(app.fig, sprintf(['Acquisition ended.\nSamples written: ' ...
                '%d\nData: %s\n\nPress Start to record another run - no ' ...
                'need to set up again.'], ...
                app.nSamplesWritten, app.dataFile), ...
                'Acquisition Complete', 'Icon', 'success');
        end
    end

    function settings = collectSettings()
        % Gather the current UI state into a plain struct whose field names
        % become the JSON keys.  Keep them self-describing: the whole point
        % of the format is that the file can be read and edited by hand.
        settings = struct();
        settings.application = 'FLIMIR_DataAcq';
        settings.settingsVersion = 1;
        settings.savedAt = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
        settings.backend = char(string(app.backendDropdown.Value));
        settings.device = char(string(app.deviceDropdown.Value));
        settings.sampleRateHz = app.sampleRateSpinner.Value;
        settings.laserPowerV = app.laserPowerSpinner.Value;
        settings.phaseShifterV = app.phaseShifterSpinner.Value;
        settings.windowSeconds = app.rollingWindowSpinner.Value;
        settings.rollingWindowEnabled = logical(app.rollingWindowCheck.Value);
        settings.updateIntervalSeconds = app.updateIntervalSpinner.Value;
        settings.detector = char(string(app.detectorDropdown.Value));
        settings.detectorHVPercent = app.detectorHVSpinner.Value;
        settings.detectorSerial = char(string(app.detectorDeviceDropdown.Value));
        settings.pmtLinked = logical(app.pmtLinkCheck.Value);
        settings.invertIntensity = logical(app.invertIntensityCheck.Value);
        settings.invertLaser = logical(app.invertLaserCheck.Value);
        settings.saveDirectory = app.saveDirEdit.Value;
        % The calibration travels with the settings as a path, not a copy:
        % the sweep itself is far too big to inline, and it is already
        % archived on disk.  A calibration the device supplied itself has
        % no file behind it and is re-adopted on selection, so it is
        % stored as blank rather than as a path that does not exist.
        if isfile(app.calibrationFile)
            settings.calibrationFile = app.calibrationFile;
        else
            settings.calibrationFile = '';
        end

        % A cell array (rather than a struct array) makes jsonencode emit a
        % JSON list even when there is exactly one extra channel
        tableData = app.extraChannelsTable.Data;
        channels = {};
        for i = 1:size(tableData, 1)
            channels{end+1} = struct( ...
                'type', char(string(tableData{i, 1})), ...
                'channel', char(string(tableData{i, 2})), ...
                'plot', logical(tableData{i, 3})); %#ok<AGROW>
        end
        settings.extraChannels = channels;

        %% Window geometry, so a rig comes back laid out the way it was left.
        %% The raw channel monitor is included when it is open; when it is
        %% not, whatever was stored last is carried through untouched
        %% rather than dropped, so closing it does not forget its place.
        settings.windows = collectWindowGeometry();
    end

    function saveSettings()
        startName = 'FLIMIR_settings.json';
        if ~isempty(app.settingsFile)
            startName = app.settingsFile;
        end
        [fileName, pathName] = uiputfile({'*.json', 'Settings files (*.json)'}, ...
            'Save Settings', startName);
        focusAppWindow();
        if isequal(fileName, 0)
            return;
        end
        fullPath = fullfile(pathName, fileName);
        writeSettingsFile(fullPath, true);
    end

    function ok = writeSettingsFile(fullPath, announce)
        ok = false;
        try
            jsonText = jsonencode(collectSettings(), 'PrettyPrint', true);

            fid = fopen(fullPath, 'w', 'n', 'UTF-8');
            if fid == -1
                error('Cannot open "%s" for writing.', fullPath);
            end
            cleanup = onCleanup(@() fclose(fid));
            fprintf(fid, '%s\n', jsonText);
            clear cleanup;  % close before reporting success

            app.settingsFile = fullPath;
            rememberSettingsPath(fullPath);
            refreshSettingsSummary();
            ok = true;
            if announce
                uialert(app.fig, sprintf('Settings saved to:\n%s', fullPath), ...
                    'Settings Saved', 'Icon', 'success');
            end
        catch ME
            uialert(app.fig, sprintf('Error saving settings:\n%s', ME.message), ...
                'Save Error');
        end
    end

    function loadSettings()
        [fileName, pathName] = uigetfile({'*.json', 'Settings files (*.json)'}, ...
            'Load Settings');
        focusAppWindow();
        if isequal(fileName, 0)
            return;
        end
        readSettingsFile(fullfile(pathName, fileName));
    end

    function ok = readSettingsFile(fullPath)
        ok = false;
        try
            fid = fopen(fullPath, 'r', 'n', 'UTF-8');
            if fid == -1
                error('Cannot open "%s" for reading.', fullPath);
            end
            cleanup = onCleanup(@() fclose(fid));
            jsonText = fread(fid, '*char')';
            clear cleanup;

            settings = jsondecode(jsonText);
            if ~isstruct(settings)
                error('File does not contain a JSON settings object.');
            end
            applySettings(settings);
            app.settingsFile = fullPath;
            rememberSettingsPath(fullPath);
            refreshSettingsSummary();
            ok = true;
        catch ME
            uialert(app.fig, sprintf('Error loading settings:\n%s\n\n%s', ...
                fullPath, ME.message), 'Load Error');
        end
    end

    % =====================================================================
    % Startup
    % =====================================================================

    function startupSettingsFile()
        % A session is always tied to a settings file: it is what makes a
        % run reproducible, and what Setup is driven from.  There is a
        % default in the application folder so the first launch has
        % something to open rather than an empty dialog.
        [fileName, pathName] = uigetfile( ...
            {'*.json', 'Settings files (*.json)'}, ...
            'Select a settings file for this session', lastSettingsPath());
        focusAppWindow();
        if isequal(fileName, 0)
            % Declining still has to land somewhere defined, so fall back
            % to the shipped defaults rather than an unconfigured app
            if isfile(defaultSettingsPath())
                readSettingsFile(defaultSettingsPath());
            end
            refreshSettingsSummary();
            return;
        end
        if ~readSettingsFile(fullfile(pathName, fileName))
            refreshSettingsSummary();
            return;
        end

        % Complete enough to run?  Then do the setup the user would have
        % done by hand.  Anything missing leaves them on the Settings tab
        % with the reason showing rather than a half-configured session.
        [complete, why] = settingsAreComplete();
        if complete
            setupAcquisition();
            if app.isSetUp
                app.tabGroup.SelectedTab = app.tabGroup.Children(1);
            end
        else
            app.tabGroup.SelectedTab = app.tabGroup.Children(2);
            uialert(app.fig, sprintf(['Loaded %s.\n\nSetup was not run ' ...
                'automatically because:\n  %s'], fileName, why), ...
                'Settings Incomplete', 'Icon', 'warning');
        end
        refreshSettingsSummary();
    end

    function g = collectWindowGeometry()
        % Position and size of each window, in pixels.
        %
        % The raw channel monitor is only recorded while it is open.  If
        % it is shut, the geometry already in the loaded settings is
        % carried forward rather than written as empty, so closing the
        % window does not erase where it used to sit.
        g = struct();
        if isvalid(app.fig)
            g.main = app.fig.Position;
        end
        if rawWindowOpen()
            g.rawChannels = app.rawFig.Position;
        elseif isfield(app, 'storedWindows') && ...
                isfield(app.storedWindows, 'rawChannels')
            g.rawChannels = app.storedWindows.rawChannels;
        end
    end

    function applyWindowGeometry(g)
        % Put the windows back where they were, if the saved place is
        % still on a screen.  A settings file written on a two-monitor rig
        % and opened on a laptop would otherwise place windows off the
        % desktop, where they cannot be dragged back.
        if isempty(g) || ~isstruct(g)
            return;
        end
        app.storedWindows = g;
        if isfield(g, 'main') && isvalid(app.fig)
            p = sanitiseWindowPosition(g.main);
            if ~isempty(p)
                app.fig.Position = p;
            end
        end
        % The raw window takes its geometry when it is next opened
        if rawWindowOpen() && isfield(g, 'rawChannels')
            p = sanitiseWindowPosition(g.rawChannels);
            if ~isempty(p)
                app.rawFig.Position = p;
            end
        end
    end

    function p = sanitiseWindowPosition(candidate)
        % Accept a stored [x y w h] only if it is well formed and leaves a
        % usable part of the title bar on some screen.  Returning empty
        % means "leave the window where it is".
        p = [];
        if ~isnumeric(candidate) || numel(candidate) ~= 4 || ...
                ~all(isfinite(candidate))
            return;
        end
        candidate = double(candidate(:)');
        if candidate(3) < 200 || candidate(4) < 150
            return;      % too small to be usable
        end

        % Union of all monitors, as [left bottom right top]
        mp = get(groot, 'MonitorPositions');
        visible = false;
        for k = 1:size(mp, 1)
            L = mp(k,1); B = mp(k,2);
            R = L + mp(k,3) - 1; T = B + mp(k,4) - 1;
            % At least 120 x 30 px of the window's top edge on this screen
            overlapW = min(candidate(1) + candidate(3), R) - max(candidate(1), L);
            overlapH = min(candidate(2) + candidate(4), T) - max(candidate(2), B);
            if overlapW >= 120 && overlapH >= 30
                visible = true;
                break;
            end
        end
        if ~visible
            return;
        end
        p = candidate;
    end

    function p = lastSettingsPath()
        % Where the settings-file dialog should open.  The file used last
        % session, if it is still there, so somebody working out of a
        % folder of per-rig settings files does not navigate back to it
        % every launch.  Falls back to the shipped default.
        %
        % Kept in MATLAB's preference store rather than in a settings
        % file, because it has to be readable before any settings file
        % has been chosen.
        p = defaultSettingsPath();
        try
            if ispref('FLIMIR', 'lastSettingsFile')
                candidate = getpref('FLIMIR', 'lastSettingsFile');
                if ischar(candidate) && isfile(candidate)
                    p = candidate;
                end
            end
        catch
            % A preference store that cannot be read is not worth failing
            % startup over
        end
    end

    function rememberSettingsPath(fullPath)
        try
            setpref('FLIMIR', 'lastSettingsFile', char(string(fullPath)));
        catch
        end
    end

    function p = defaultSettingsPath()
        p = fullfile(fileparts(mfilename('fullpath')), ...
            'FLIMIR_default_settings.json');
    end

    function [tf, why] = settingsAreComplete()
        % The minimum needed for Setup to succeed unattended
        tf = false;
        why = '';
        if isempty(app.backendDropdown.Value)
            why = 'no DAQ backend selected';
            return;
        end
        if isempty(app.deviceDropdown.Value) || ...
                strcmp(app.deviceDropdown.Value, 'none')
            why = 'the DAQ device in the file is not attached';
            return;
        end
        saveDir = strtrim(app.saveDirEdit.Value);
        if isempty(saveDir)
            why = 'no save directory';
            return;
        end
        if ~isfolder(saveDir)
            why = sprintf('the save directory does not exist: %s', saveDir);
            return;
        end
        tf = true;
    end

    function applySettings(settings)
        % Every field is optional, so a hand-written file containing only
        % the keys of interest loads fine.
        setSpinnerSafe(app.sampleRateSpinner, pickField(settings, 'sampleRateHz'));
        setSpinnerSafe(app.laserPowerSpinner, pickField(settings, 'laserPowerV'));
        setSpinnerSafe(app.phaseShifterSpinner, pickField(settings, 'phaseShifterV'));
        setSpinnerSafe(app.rollingWindowSpinner, pickField(settings, 'windowSeconds'));
        setSpinnerSafe(app.updateIntervalSpinner, ...
            pickField(settings, 'updateIntervalSeconds'));
        app.blockPeriod = app.updateIntervalSpinner.Value;

        rollFlag = pickField(settings, 'rollingWindowEnabled');
        if isscalar(rollFlag) && (islogical(rollFlag) || ...
                (isnumeric(rollFlag) && ismember(rollFlag, [0 1])))
            app.rollingWindowCheck.Value = logical(rollFlag);
        end

        setSpinnerSafe(app.detectorHVSpinner, ...
            pickField(settings, 'detectorHVPercent'));
        % The serial is applied after the detector type, since changing
        % the type re-scans and would otherwise clear it
        wantedSerial = pickField(settings, 'detectorSerial');

        invLaser = pickField(settings, 'invertLaser');
        if isscalar(invLaser) && (islogical(invLaser) || (isnumeric(invLaser) && ismember(invLaser, [0 1])))
            app.invertLaserCheck.Value = logical(invLaser);
        end

        invFlag = pickField(settings, 'invertIntensity');
        if isscalar(invFlag) && (islogical(invFlag) || (isnumeric(invFlag) && ismember(invFlag, [0 1])))
            app.invertIntensityCheck.Value = logical(invFlag);
        end

        linkFlag = pickField(settings, 'pmtLinked');
        if isscalar(linkFlag) && (islogical(linkFlag) || (isnumeric(linkFlag) && ismember(linkFlag, [0 1])))
            app.pmtLinkCheck.Value = logical(linkFlag);
        end

        detValue = pickField(settings, 'detector');
        if ~isempty(detValue)
            try
                app.detectorDropdown.Value = char(string(detValue));
                detectorSelectionChanged();
            catch
                % An unknown detector name leaves the current selection
            end
        end
        if ~isempty(wantedSerial)
            s = char(string(wantedSerial));
            if any(strcmp(s, app.detectorDeviceDropdown.ItemsData))
                app.detectorDeviceDropdown.Value = s;
            end
        end

        applyWindowGeometry(pickField(settings, 'windows'));

        saveDir = pickField(settings, 'saveDirectory');
        if (ischar(saveDir) || isstring(saveDir)) && isfolder(saveDir)
            app.saveDirEdit.Value = char(saveDir);
        end

        extraChannels = pickField(settings, 'extraChannels');
        if ~isempty(extraChannels)
            app.extraChannelsTable.Data = decodeExtraChannels(extraChannels);
        end

        backendValue = pickField(settings, 'backend');
        if ~isempty(backendValue)
            try
                app.backendDropdown.Value = backendValue;
                refreshDevices();
            catch
                % That backend is not installed - keep the current one
            end
        end

        deviceValue = pickField(settings, 'device');
        if ~isempty(deviceValue)
            try
                app.deviceDropdown.Value = deviceValue;
                updateDeviceTooltip();
            catch
                % Device is not attached right now - leave the selection be
            end
        end

        % Re-adopt the calibration the settings point at.  A missing or
        % unusable file is reported but does not stop the rest loading.
        calFile = pickField(settings, 'calibrationFile');
        if (ischar(calFile) || isstring(calFile)) && ~isempty(char(calFile))
            calFile = char(calFile);
            if isfile(calFile)
                applyCalibrationFile(calFile, false);
            else
                uialert(app.fig, sprintf(['The calibration file named in ' ...
                    'these settings no longer exists:\n%s\n\nEverything ' ...
                    'else loaded; run or load a calibration before ' ...
                    'acquiring.'], calFile), 'Calibration File Missing');
            end
        end

        rollingModeChanged();
        % Loaded settings describe a different configuration
        invalidateSetup();
    end

    function value = pickField(settings, name)
        % Empty when the key is absent, so callers can treat it as optional
        if isfield(settings, name)
            value = settings.(name);
        else
            value = [];
        end
    end

    function setSpinnerSafe(spinner, value)
        % Ignore missing or nonsense values, and clamp anything outside the
        % control's own limits rather than throwing
        if isempty(value) || ~isnumeric(value) || ~isscalar(value) || ~isfinite(value)
            return;
        end
        spinner.Value = min(max(value, spinner.Limits(1)), spinner.Limits(2));
    end

    function rows = decodeExtraChannels(extraChannels)
        % jsondecode gives a struct array for a uniform JSON list and a cell
        % array when the entries have differing keys, so handle both
        if iscell(extraChannels)
            items = extraChannels;
        elseif isstruct(extraChannels)
            items = num2cell(extraChannels);
        else
            rows = cell(0, 3);
            return;
        end

        rows = cell(0, 3);
        for i = 1:numel(items)
            item = items{i};
            if ~isstruct(item) || ~isfield(item, 'channel')
                continue;
            end
            if isfield(item, 'type')
                chType = char(string(item.type));
            else
                chType = 'Analog';
            end
            if ~ismember(chType, {'Analog', 'Digital'})
                chType = 'Analog';
            end
            if isfield(item, 'plot')
                plotFlag = logical(item.plot);
            else
                plotFlag = true;
            end
            rows(end+1, :) = {chType, char(string(item.channel)), plotFlag}; %#ok<AGROW>
        end
    end

    % =====================================================================
    % Detector
    %
    % Kept deliberately thin.  The app decides WHEN the high voltage
    % should be on - around a calibration, around a run - and the device
    % class decides HOW.  Selecting 'none' makes every call here a no-op,
    % so a rig with no controllable detector behaves exactly as before.
    % =====================================================================

    function intensityInversionChanged()
        % Flipping the channel invalidates any calibration taken the
        % other way up: the dark offset would go on with the wrong sign,
        % and the mixer calibration's meanVDC would too.  Say so rather
        % than letting a stale record be applied.
        stale = {};
        if ~isempty(app.darkCalibration) && ...
                isfield(app.darkCalibration, 'invertIntensity') && ...
                app.darkCalibration.invertIntensity ~= app.invertIntensityCheck.Value
            stale{end+1} = 'the dark calibration';
        end
        if ~isempty(app.mixerCalibration) && ...
                isfield(app.mixerCalibration, 'invertIntensity') && ...
                app.mixerCalibration.invertIntensity ~= app.invertIntensityCheck.Value
            stale{end+1} = 'the mixer calibration';
        end
        if ~isempty(stale)
            uialert(app.fig, sprintf(['Intensity inversion changed, so ' ...
                '%s no longer matches the data.\n\nThose offsets were ' ...
                'measured the other way up; applying them now would be ' ...
                'wrong by twice the offset. Re-run Dark%s.'], ...
                strjoin(stale, ' and '), ...
                ternary(numel(stale) > 1, ' and Calibrate', '')), ...
                'Calibration No Longer Matches', 'Icon', 'warning');
        end
        refreshSettingsSummary();
    end

    function scanDetectorDevices(announce)
        % Populate the head list from what is on the USB bus now.  Keeps
        % the current selection if it is still attached, so a re-scan
        % does not silently repoint the app at a different head.
        if nargin < 1
            announce = false;
        end
        wanted = app.detectorDeviceDropdown.Value;
        switch app.detectorDropdown.Value
            case 'thorlabsPMT2100'
                found = ThorlabsPMT.listDevices();
            otherwise
                found = struct('id', {}, 'description', {});
        end

        if isempty(found)
            app.detectorDeviceDropdown.Items = {'(none found)'};
            app.detectorDeviceDropdown.ItemsData = {''};
            app.detectorDeviceDropdown.Value = '';
            app.detectorDeviceDropdown.Enable = 'off';
        else
            app.detectorDeviceDropdown.Items = {found.description};
            app.detectorDeviceDropdown.ItemsData = {found.id};
            app.detectorDeviceDropdown.Enable = 'on';
            if any(strcmp(wanted, {found.id}))
                app.detectorDeviceDropdown.Value = wanted;
            else
                app.detectorDeviceDropdown.Value = found(1).id;
            end
        end
        app.detectorScanBtn.Enable = ...
            ternary(strcmp(app.detectorDropdown.Value, 'none'), 'off', 'on');

        if announce
            uialert(app.fig, sprintf('Found %d detector head(s) on USB.', ...
                numel(found)), 'Detector Scan', ...
                'Icon', ternary(isempty(found), 'warning', 'info'));
        end
        refreshSettingsSummary();
    end

    function detectorSelectionChanged()
        % Changing detector invalidates the setup: the new one has to be
        % opened, and any calibration taken with the old one described
        % different hardware.
        closeDetector();
        scanDetectorDevices();
        if app.isSetUp
            app.isSetUp = false;
            app.startBtn.Enable = 'off';
            setCalibButtonState();
        end
    end

    function detectorHVChanged()
        % If the HV is live, follow the spinner immediately so what the
        % user sees on the chart matches what the box says.
        if app.detectorPowered && ~isempty(app.detector)
            try
                app.detector.setGain(app.detectorHVSpinner.Value);
            catch ME
                uialert(app.fig, sprintf(['Could not change the detector ' ...
                    'HV:\n%s'], ME.message), 'Detector Error');
            end
        end
    end

    function tf = openDetector()
        % Returns true when there is nothing to do or the detector opened.
        closeDetector();
        tf = true;
        switch app.detectorDropdown.Value
            case 'none'
                return;
            case 'thorlabsPMT2100'
                try
                    app.detector = ThorlabsPMT(app.detectorDeviceDropdown.Value);
                catch ME
                    tf = false;
                    uialert(app.fig, sprintf(['Could not open the ' ...
                        'Thorlabs PMT:\n%s\n\nSelect "None" to run ' ...
                        'without detector control.'], ME.message), ...
                        'Detector Error');
                end
        end
        updateDetectorLamp();
    end

    function closeDetector()
        if ~isempty(app.detector)
            try
                delete(app.detector);   % powers down if it was powered up
            catch
            end
        end
        app.detector = [];
        app.detectorPowered = false;
        updateDetectorLamp();
    end

    function tf = setDetectorPower(on)
        % Bring the HV up or down and report whether the detector is now
        % in the requested state.  With no detector selected, or with the
        % link switched off, this is a no-op that still reports success,
        % so callers do not have to branch on whether one is present.
        tf = true;
        if ~app.pmtLinkCheck.Value
            return;     % detector is the operator's to switch, not ours
        end
        if isempty(app.detector) || ~isvalid(app.detector)
            app.detectorPowered = false;
            updateDetectorLamp();
            return;
        end
        try
            if on
                app.detector.powerOn(app.detectorHVSpinner.Value);
            else
                app.detector.powerOff();
            end
            app.detectorPowered = logical(on);
        catch ME
            tf = false;
            app.detectorPowered = false;
            uialert(app.fig, sprintf('Detector power %s failed:\n%s', ...
                ternary(on, 'on', 'off'), ME.message), 'Detector Error');
        end
        updateDetectorLamp();
        % The head needs a moment for the HV to settle before anything
        % reads it; without this the first block of a run is taken during
        % the transient.
        if tf && on
            pause(0.5);
        end
    end

    function refreshSettingsSummary()
        % Everything that defines the current configuration, in one
        % readable block: the settings you typed, and the ones that only
        % exist because a calibration measured them.
        if ~isfield(app, 'settingsSummary') || ~isvalid(app.settingsSummary)
            return;
        end
        L = {};
        L{end+1} = sprintf('SETTINGS FILE  %s', emptyAs(app.settingsFile, '(none)'));
        L{end+1} = '';
        L{end+1} = '--- acquisition ---';
        L{end+1} = sprintf('  backend        %s', app.backendDropdown.Value);
        L{end+1} = sprintf('  device         %s', string(app.deviceDropdown.Value));
        L{end+1} = sprintf('  sample rate    %g Hz', app.sampleRateSpinner.Value);
        L{end+1} = sprintf('  laser power    %.2f V', app.laserPowerSpinner.Value);
        L{end+1} = sprintf('  phase shifter  %.2f V', app.phaseShifterSpinner.Value);
        L{end+1} = sprintf('  window         %g s, update %g s', ...
            app.rollingWindowSpinner.Value, app.updateIntervalSpinner.Value);
        L{end+1} = sprintf('  rolling window %s', onOff(app.rollingWindowCheck.Value));
        L{end+1} = sprintf('  invert ai4     %s', onOff(app.invertIntensityCheck.Value));
        L{end+1} = sprintf('  invert laser   %s  (off = %.1f V)', ...
            onOff(app.invertLaserCheck.Value), laserOffVolts());
        L{end+1} = sprintf('  phase monitor  %s %s', ...
            onOff(app.phaseMonitorCheck.Value), strtrim(app.phaseMonitorEdit.Value));
        L{end+1} = sprintf('  save directory %s', ...
            emptyAs(strtrim(app.saveDirEdit.Value), '(none selected)'));
        nExtra = size(app.extraChannelsTable.Data, 1);
        L{end+1} = sprintf('  extra channels %d', nExtra);
        for r = 1:nExtra
            L{end+1} = sprintf('      %-8s %-8s plot=%d', ...
                string(app.extraChannelsTable.Data{r,1}), ...
                string(app.extraChannelsTable.Data{r,2}), ...
                logical(app.extraChannelsTable.Data{r,3})); %#ok<AGROW>
        end

        L{end+1} = '';
        L{end+1} = '--- detector ---';
        L{end+1} = sprintf('  selected       %s', app.detectorDropdown.Value);
        L{end+1} = sprintf('  head           %s', emptyAs(app.detectorDeviceDropdown.Value, '(none)'));
        L{end+1} = sprintf('  HV setting     %g %%', app.detectorHVSpinner.Value);
        L{end+1} = sprintf('  linked         %s', onOff(app.pmtLinkCheck.Value));
        L{end+1} = sprintf('  HV now         %s', onOff(app.detectorPowered));

        L{end+1} = '';
        L{end+1} = '--- dark calibration (measured) ---';
        if isempty(app.darkCalibration)
            L{end+1} = '  none - offsets assumed zero';
        else
            d = app.darkCalibration;
            L{end+1} = sprintf('  taken          %s', d.timestamp);
            L{end+1} = sprintf('  offsetVIF      %s mV', ...
                sprintf('%+.3f ', 1000 * d.offsetVIF));
            L{end+1} = sprintf('  offsetDC       %+.3f mV', 1000 * d.offsetDC);
            L{end+1} = sprintf('  worst noise    %.3f mV sd', ...
                1000 * max([d.stats.sd]));
            L{end+1} = sprintf('  stable         %s', yesNo(d.stable));
        end

        L{end+1} = '';
        L{end+1} = '--- mixer calibration (measured) ---';
        mc = app.mixerCalibration;
        if isempty(mc)
            L{end+1} = '  none - lifetime and phasor are unavailable';
            L{end+1} = '  Start will record and display intensity only';
        else
            L{end+1} = sprintf('  file           %s', ...
                emptyAs(app.calibrationFile, '(from the device)'));
            L{end+1} = sprintf('  taken          %s', getOrDefault(mc, 'timestamp', '?'));
            L{end+1} = sprintf('  source         %g s ramp, %g Hz', ...
                getOrDefault(mc, 'sourceRampSeconds', NaN), ...
                getOrDefault(mc, 'sourceRate', NaN));
            if isfield(mc, 'combine')
                L{end+1} = sprintf('  combine        %s (%d ramp(s))', ...
                    mc.combine, getOrDefault(mc, 'nRampsAveraged', 1));
            end
            if isfield(mc, 'controlVoltRange')
                L{end+1} = sprintf('  V covered      %.2f to %.2f V', ...
                    mc.controlVoltRange(1), mc.controlVoltRange(2));
            end
            L{end+1} = sprintf('  tau_bar        %.3f ns', 1e9 * mc.tau_bar);
            L{end+1} = sprintf('  laser freq     %.1f MHz', mc.laserFreq / 1e6);
            L{end+1} = sprintf('  phi_actual     %s deg', ...
                sprintf('%9.4f', rad2deg(mc.phi_actual)));
            L{end+1} = sprintf('  max_VIF        %s V', sprintf('%9.5f', mc.max_VIF));
            L{end+1} = sprintf('  min_VIF        %s V', sprintf('%9.5f', mc.min_VIF));
            L{end+1} = sprintf('  k_est          %s V', sprintf('%9.5f', mc.k_est));
            L{end+1} = sprintf('  o_est          %s V', sprintf('%9.5f', mc.o_est));
            L{end+1} = sprintf('  meanVDC        %.6f V', mc.meanVDC);
            L{end+1} = sprintf('  MoverB         %.6f', mc.MoverB);
            L{end+1} = sprintf('  offsetVIF      %s mV', ...
                sprintf('%+.3f ', 1000 * mc.offsetVIF));
            L{end+1} = sprintf('  offsetDC       %+.3f mV', 1000 * mc.offsetDC);
        end

        app.settingsSummary.Value = L(:);
        updateModeLabel();
    end

    function updateModeLabel()
        % Say plainly what a run will compute, because it changes with
        % the calibration and it is not otherwise obvious from the plots
        if ~isfield(app, 'modeLabel') || ~isvalid(app.modeLabel)
            return;
        end
        if isempty(app.mixerCalibration)
            app.modeLabel.Text = 'No calibration: intensity only';
            app.modeLabel.FontColor = [0.75 0.35 0];
        else
            app.modeLabel.Text = 'Calibrated: lifetime, intensity and phasor';
            app.modeLabel.FontColor = [0.2 0.5 0.2];
        end
    end

    function s = onOff(tf)
        s = ternary(logical(tf), 'on', 'off');
    end

    function s = yesNo(tf)
        s = ternary(logical(tf), 'yes', 'NO');
    end

    function s = emptyAs(v, alt)
        s = char(string(v));
        if isempty(strtrim(s))
            s = alt;
        end
    end

    function v = getOrDefault(s, name, dflt)
        if isfield(s, name)
            v = s.(name);
        else
            v = dflt;
        end
    end

    function updateDetectorLamp()
        if ~isfield(app, 'detectorLamp') || ~isvalid(app.detectorLamp)
            return;
        end
        if app.detectorPowered
            c = [0.1 0.85 0.1];
            tip = sprintf('Detector HV ON at %g%%', app.detectorHVSpinner.Value);
            txt = sprintf('Detector: ON (%g%%)', app.detectorHVSpinner.Value);
        elseif isempty(app.detector)
            c = [0.75 0.75 0.75];
            tip = 'No detector under software control';
            txt = 'Detector: none';
        else
            c = [0.35 0.35 0.35];
            tip = 'Detector open, HV off';
            txt = 'Detector: off';
        end
        app.detectorLamp.Color = c;
        app.detectorLamp.Tooltip = tip;
        % The same state, mirrored onto the run tab
        if isfield(app, 'runLamp') && isvalid(app.runLamp)
            app.runLamp.Color = c;
            app.runLamp.Tooltip = tip;
            app.detectorStatusLabel.Text = txt;
        end
    end

    function out = ternary(cond, a, b)
        if cond
            out = a;
        else
            out = b;
        end
    end

    function runDarkCalibration()
        if app.isRunning
            uialert(app.fig, ['Stop the acquisition before measuring ' ...
                'offsets.'], 'Acquisition Running');
            return;
        end
        if ~app.isSetUp || isempty(app.device) || ~isvalid(app.device)
            uialert(app.fig, 'Run Setup Acquisition first.', 'Setup Required');
            return;
        end

        releaseLaserToggle();
        % Same exclusivity as the sweep: the measurement wants the
        % channels to itself, and the session goes back afterwards
        cleanupDAQ();
        setConfigEnabled(true);

        % The offsets have to describe the electronics as they will be
        % during the recording, and enabling the head moves the DC
        % channel by about 100 mV on this rig.  So the HV comes up for
        % the dark measurement too, at the same setting acquisition will
        % use.  The light is blocked by hand; the high voltage is not.
        if ~setDetectorPower(true)
            restoreAcquisitionSession();
            return;
        end
        darkData = dark_calibration(app);
        setDetectorPower(false);
        restoreAcquisitionSession();

        if isempty(darkData)
            return;   % cancelled or failed
        end

        % A second of data says whether the channels are quiet now; only
        % the previous measurement says whether they are quiet over the
        % hours an experiment actually takes.  This board's dark level
        % wanders far more between runs than within one.
        driftNote = compareWithPreviousDark(app.darkCalibration, darkData);
        adoptDarkCalibration(darkData);

        if isempty(darkData.savedTo)
            archiveNote = sprintf('\n\nWARNING: it could not be saved.');
        else
            archiveNote = sprintf('\n\nArchived to:\n%s', darkData.savedTo);
        end
        if darkData.stable
            icon = 'success';
            headline = 'Offsets measured, all channels stable.';
        else
            icon = 'warning';
            headline = sprintf(['Offsets measured, but %s did not pass ' ...
                'the stability check.\nThe offsets are still applied - ' ...
                'trust them less, and see the console for why.'], ...
                strjoin({darkData.stats(~[darkData.stats.ok]).id}, ', '));
        end
        if ~isempty(driftNote)
            driftNote = sprintf('\n\n%s', driftNote);
        end
        uialert(app.fig, sprintf('%s\n\n%s%s%s', headline, ...
            offsetSummaryLine(darkData), driftNote, archiveNote), ...
            'Dark Calibration', 'Icon', icon);
    end

    function note = compareWithPreviousDark(prev, now_)
        % How far the offsets have moved since the last measurement, which
        % is the thing that decides how often this has to be re-run.
        note = '';
        if isempty(prev) || ~isfield(prev, 'offsetVIF')
            return;
        end
        dVIF = 1000 * (now_.offsetVIF - prev.offsetVIF);
        dDC  = 1000 * (now_.offsetDC - prev.offsetDC);
        % A shift is worth remarking on once it clears both the noise it
        % could be hiding in and a flat floor
        sd = 1000 * max([now_.stats.sd]);
        limit = max(10, 5 * sd);
        moved = max(abs([dVIF dDC]));
        note = sprintf('Change since %s: VIF %s mV, VDC %+.1f mV.', ...
            prev.timestamp, ...
            strjoin(arrayfun(@(v) sprintf('%+.1f', v), dVIF, ...
            'UniformOutput', false), ' '), dDC);
        if moved > limit
            note = sprintf(['%s\nThat is more than %.0f mV, so the ' ...
                'offsets are drifting between runs - measure dark close ' ...
                'in time to the data it will be applied to.'], note, limit);
        end
        fprintf('%s\n', note);
    end

    function adoptDarkCalibration(darkData)
        % One place where the measured offsets reach everything that uses
        % them: the stored record, the live lifetime path (which reads
        % them off mixerCalibration), and the button state.
        app.darkCalibration = darkData;
        if ~isempty(app.mixerCalibration)
            app.mixerCalibration.offsetVIF = darkData.offsetVIF;
            app.mixerCalibration.offsetDC = darkData.offsetDC;
        end
        setCalibButtonState();
        refreshSettingsSummary();
    end

    function s = offsetSummaryLine(darkData)
        s = sprintf('Offsets (mV): %s | VDC %.2f\nWorst noise %.2f mV sd', ...
            strjoin(arrayfun(@(v) sprintf('%+.2f', 1000 * v), ...
            darkData.offsetVIF, 'UniformOutput', false), ' '), ...
            1000 * darkData.offsetDC, ...
            1000 * max([darkData.stats.sd]));
    end

    function s = stabilitySuffix(darkData)
        if darkData.stable
            s = ', stable';
        else
            s = ', UNSTABLE';
        end
    end

    function runCalibration(mode)
        if app.isRunning
            uialert(app.fig, ['Stop the acquisition before running a ' ...
                'calibration sweep.'], 'Acquisition Running');
            return;
        end

        % Setup is a prerequisite.  It is what validates the device, fixes
        % the channel list and the sample rate, and pins down the save
        % directory the timestamped calibration gets written to.
        if ~app.isSetUp || isempty(app.device) || ~isvalid(app.device)
            uialert(app.fig, ['Run Setup Acquisition first.' newline newline ...
                'Setup fixes the device, the channel list and the sample ' ...
                'rate the sweep will use, and the data folder the ' ...
                'calibration file is written to.'], 'Setup Required');
            return;
        end

        % The sweep needs exclusive use of the same channels the streaming
        % session holds, so hand them over for the duration and rebuild
        % the session afterwards.
        cleanupDAQ();
        setConfigEnabled(true);

        releaseLaserToggle();

        % Calibrate the rig in the state it will be recording in, which
        % means with the detector at its working HV
        if ~setDetectorPower(true)
            restoreAcquisitionSession();
            return;
        end
        powerDown = onCleanup(@() setDetectorPower(false));

        % The monitor's Rerun button covers a sweep you can already see is
        % bad; this covers the one that only looks bad once it is scored.
        while true
            calibrationData = calibration(app, mode);
            if isempty(calibrationData)
                restoreAcquisitionSession();
                return;   % aborted, cancelled, or failed before recording
            end
            if ~reportCalibration(calibrationData)
                break;
            end
        end
        restoreAcquisitionSession();
    end

    function again = reportCalibration(calibrationData)
    % Show how the sweep scored and return true if the user wants another.

        % calibration.m archives every sweep that produced data, so there
        % is a file to point at whether or not the fit was usable
        archived = '';
        if isfield(calibrationData, 'savedTo')
            archived = calibrationData.savedTo;
        end
        if isempty(archived)
            archiveNote = sprintf('\n\nWARNING: the sweep could not be saved.');
        else
            archiveNote = sprintf('\n\nArchived to:\n%s', archived);
        end

        % What the dark baseline found, so a bad offset measurement is
        % visible here rather than only in the console
        darkNote = '';
        if isfield(calibrationData, 'darkNote') && ~isempty(calibrationData.darkNote)
            darkNote = sprintf('\n\n%s', calibrationData.darkNote);
        end

        % The loopback's verdict on the output path.  It does not feed the
        % calibration, so the only place it can do its job is here.
        if isfield(calibrationData, 'results') ...
                && isfield(calibrationData.results, 'monitorCheck') ...
                && ~isempty(calibrationData.results.monitorCheck)
            m = calibrationData.results.monitorCheck;
            if m.tracking
                darkNote = sprintf(['%s\n\nPhase monitor OK: gain %.4f, ' ...
                    'offset %+.1f mV, lag %d scan(s) (%.2f ms).'], ...
                    darkNote, m.gain, 1000 * m.offset, m.lagSamples, m.lagMs);
            else
                darkNote = sprintf(['%s\n\nPHASE MONITOR NOT TRACKING: %s.' ...
                    '\nThe calibration used the commanded phase axis and ' ...
                    'is unaffected, but check the loopback wiring.'], ...
                    darkNote, m.note);
            end
        end

        % Arm the real-time lifetime path with the fresh calibration
        if isfield(calibrationData, 'results') ...
                && isfield(calibrationData.results, 'mixerCalibration') ...
                && ~isempty(calibrationData.results.mixerCalibration)
            app.mixerCalibration = calibrationData.results.mixerCalibration;
            setCalibrationFile(archived);
            refreshSettingsSummary();
            msg = sprintf(['Mixer calibration updated from the %g s ramp.' ...
                '\nLifetime and phasor will now be computed during ' ...
                'acquisition.%s%s'], ...
                app.mixerCalibration.sourceRampSeconds, darkNote, archiveNote);
            choice = uiconfirm(app.fig, msg, 'Calibration Applied', ...
                'Options', {'OK', 'Rerun'}, 'DefaultOption', 1, ...
                'CancelOption', 1, 'Icon', 'success');
        else
            msg = sprintf(['The sweep ran but produced no usable mixer ' ...
                'calibration, so the previous one (if any) is unchanged. ' ...
                'Check the console summary for which ramps were ' ...
                'rejected.%s%s'], darkNote, archiveNote);
            choice = uiconfirm(app.fig, msg, 'No Usable Calibration', ...
                'Options', {'OK', 'Rerun'}, 'DefaultOption', 1, ...
                'CancelOption', 1, 'Icon', 'warning');
        end
        again = strcmp(choice, 'Rerun');
    end

    function restoreAcquisitionSession()
        % Put back the streaming and output sessions the calibration took
        % over, so Start is available again without the user having to
        % press Setup a second time.  If it cannot be rebuilt, fall back
        % to requiring an explicit Setup rather than pretending.
        if ~app.isSetUp
            return;
        end
        try
            app.device.openInput(app.inputChannels, app.sampleRate, ...
                max(1, round(app.sampleRate * app.updateInterval)), ...
                @(blockData) dataCallback(blockData));
            app.device.openOutputs();
            app.startBtn.Enable = 'on';
            setCalibButtonState();
            set(app.setupBtn, 'Enable', 'off');
        catch ME
            fprintf('Could not restore the acquisition session: %s\n', ME.message);
            app.isSetUp = false;
            set(app.setupBtn, 'Enable', 'on');
            app.startBtn.Enable = 'off';
            app.calibBtn.Enable = 'off';
            uialert(app.fig, sprintf(['The calibration finished but the ' ...
                'acquisition session could not be reopened:\n%s\n\nRun ' ...
                'Setup Acquisition again.'], ME.message), ...
                'Setup Required');
        end
    end

    function cleanupDAQ()
        % Release the hardware sessions but keep the device object, so the
        % same selection can be set up again without rediscovering it.
        if ~isempty(app.device) && isvalid(app.device)
            try
                app.device.closeDevice();
            catch ME
                fprintf('Error releasing device: %s\n', ME.message);
            end
        end
    end

    function closeFigure()
        % Clean up on window close
        if app.isRunning
            endAcquisition(true);
        end
        % The detector goes down before the DAQ: it is the thing with
        % high voltage on it, and it must not be left energised by a
        % window close
        closeDetector();
        releaseDevice();
        if app.fid ~= -1
            fclose(app.fid);
            app.fid = -1;
        end
        if rawWindowOpen()
            delete(app.rawFig);
        end
        delete(app.fig);
    end

end
