classdef FlimirDaqLabJack < FlimirDaqDevice
%FLIMIRDAQLABJACK  LabJack T7 backend, via the LJM .NET assembly.
%
%   dev = FlimirDaqLabJack('470019xxx')
%
%   Talks to a T7 over USB using LabJack's LJM library through its .NET
%   wrapper (LabJack.LJM.dll), which needs no compiler on the MATLAB side.
%   Install the LJM software from LabJack; this class finds the assembly
%   in the default location or on the GAC.
%
%   MEASURED ON A T7 OVER USB (firmware 1.0215):
%     - DAC to AIN loopback agrees to about 1 mV from 0 to 4 V.  The DACs
%       saturate near 4.93 V, so treat 4.9 V as the usable ceiling rather
%       than the nominal 5 V.
%     - Streaming 5 analog inputs runs to about 21 kHz per channel
%       (~105 kSamples/s aggregate); above that LJM rejects the rate.
%     - A single eReadName costs ~1.5 ms of USB round trip, so per-sample
%       reads are useless for acquisition - everything goes through
%       stream mode.
%     - eWriteName costs ~0.24 ms and works while a stream is running,
%       which is what lets the laser and phase levels be changed live.
%
%   TWO LIMITS THAT SHAPE THE CALIBRATION SWEEP:
%     - The DACs reach only ~4.9 V, so a phase shifter specified over
%       0-10 V cannot be driven to the top of its range from a T7.  The
%       sweep clips to what the board can emit and warns.
%     - PeriodicStreamOut refuses a loop longer than 8192 values, so the
%       sweep's sample rate is capped to make the whole waveform fit one
%       buffer period.  maxSweepScans reports that to the caller.
%
%   Wiring the phase output back into a spare analog input (the app's
%   Phase Monitor option) is worth doing here: the calibration then uses
%   the phase voltage it measured on the same scan clock as the mixers,
%   rather than assuming the stream-out and stream-in are aligned.
%
%   See also FLIMIRDAQDEVICE, FLIMIRDAQNI, FLIMIRDAQSIMULATED.

    properties (Constant, Access = private)
        ASSEMBLY_PATHS = { ...
            'C:\Program Files (x86)\LabJack\Drivers\LabJack.LJM.dll', ...
            'C:\Program Files\LabJack\Drivers\LabJack.LJM.dll'}
        DAC_CEILING = 4.9   % usable DAC ceiling, measured (nominal 5 V)
        STREAM_OUT_MAX_VALUES = 8192   % measured PeriodicStreamOut limit
    end

    properties (Access = private)
        Handle = 0
        InputChannels = []
        InputRate = 1000
        BlockSize = 100
        OnBlock = []
        ScanAddresses = []
        InputTimer = []
        Streaming = false
        OutputsOpen = false
    end

    % ---------------------------------------------------------------------
    methods (Static)
        function name = backendName()
            name = 'LabJack T7';
        end

        function devices = listDevices()
            devices = struct('id', {}, 'description', {});
            if ~FlimirDaqLabJack.loadAssembly()
                return;
            end
            % LJM has a ListAll call, but opening the first available T7
            % and reading its serial is simpler and confirms it actually
            % responds.  The handle is closed again straight away.
            h = 0;
            try
                [err, h] = LabJack.LJM.OpenS('T7', 'USB', 'ANY', h);
                if int32(err) ~= 0
                    return;
                end
            catch
                return;   % nothing attached
            end
            try
                serial = 0;
                [~, serial] = LabJack.LJM.eReadName(h, 'SERIAL_NUMBER', serial);
                fw = 0;
                [~, fw] = LabJack.LJM.eReadName(h, 'FIRMWARE_VERSION', fw);
                devices(1).id = sprintf('%d', round(serial));
                devices(1).description = sprintf('LabJack T7 over USB, firmware %.4f', fw);
            catch
            end
            try
                LabJack.LJM.Close(h);
            catch
            end
        end
    end

    % ---------------------------------------------------------------------
    methods (Static, Access = private)
        function ok = loadAssembly()
            persistent loaded
            if ~isempty(loaded)
                ok = loaded;
                return;
            end
            ok = false;
            % Already in the GAC from a previous session?
            try
                NET.addAssembly('LabJack.LJM');
                ok = true;
            catch
                for i = 1:numel(FlimirDaqLabJack.ASSEMBLY_PATHS)
                    p = FlimirDaqLabJack.ASSEMBLY_PATHS{i};
                    if isfile(p)
                        try
                            NET.addAssembly(p);
                            ok = true;
                            break;
                        catch
                        end
                    end
                end
            end
            loaded = ok;
        end
    end

    % ---------------------------------------------------------------------
    methods
        function obj = FlimirDaqLabJack(deviceID)
            if nargin < 1
                deviceID = 'ANY';
            end
            obj.DeviceID = char(string(deviceID));
        end

        function tf = supportsClockedSweep(~)
            tf = true;
        end

        function range = outputVoltageRange(~)
            % Measured: the T7 DACs saturate around 4.93 V, so a phase
            % shifter wanting the full 0-10 V cannot be driven to the top
            % of its range from this board.
            range = [0 FlimirDaqLabJack.DAC_CEILING];
        end

        function n = maxSweepScans(~)
            % PeriodicStreamOut refuses a loop longer than this; measured
            % on the T7, 8192 values is accepted and 16384 is not
            % (STREAM_OUT_LOOP_TOO_BIG).
            n = FlimirDaqLabJack.STREAM_OUT_MAX_VALUES;
        end

        % --- channel naming -------------------------------------------
        function ids = defaultInputChannels(~, n)
            ids = arrayfun(@(k) sprintf('AIN%d', k), 0:n-1, ...
                'UniformOutput', false);
        end

        function id = laserOutputChannel(~);   id = 'DAC0'; end
        function id = phaseOutputChannel(~);   id = 'DAC1'; end
        function id = shutterOutputChannel(~); id = 'FIO0'; end

        function ids = suggestExtraChannel(obj, channelType, used)
            % The T7 has only two DACs and its digital lines are named
            % FIO/EIO/CIO/MIO rather than <prefix><n> from a single family
            used = [used(:); obj.reservedChannels()'];
            if strcmpi(channelType, 'Analog')
                first = 5;   % AIN0-AIN4 are the FLIM channels
                fmt = 'AIN%d';
                last = 13;
            else
                first = 1;   % FIO0 is the shutter
                fmt = 'FIO%d';
                last = 7;
            end
            for k = first:last
                ids = sprintf(fmt, k);
                if ~any(strcmpi(ids, used))
                    return;
                end
            end
            ids = sprintf(fmt, first);
        end

        % --- continuous input -----------------------------------------
        function openInput(obj, channels, rate, blockSize, onBlock)
            obj.stopInput();
            obj.ensureOpen();

            % Stream mode covers the analog inputs.  Streaming the digital
            % lines needs a different scan-list entry that is not wired up
            % here, so refuse rather than quietly returning the wrong data.
            for i = 1:numel(channels)
                if strcmpi(channels(i).type, 'Digital')
                    error('FlimirDaqLabJack:digitalInputUnsupported', ...
                        ['This backend does not yet stream digital inputs ' ...
                         '(channel "%s"). Remove it from the extra ' ...
                         'channels list.'], channels(i).id);
                end
            end

            obj.InputChannels = channels;
            obj.InputRate = rate;
            obj.BlockSize = max(1, round(blockSize));
            obj.OnBlock = onBlock;
            obj.ScanAddresses = obj.namesToAddresses({channels.id});
        end

        function startInput(obj)
            if isempty(obj.OnBlock)
                error('FlimirDaqLabJack:noInput', 'Call openInput first.');
            end
            obj.stopInput();

            nCh = numel(obj.InputChannels);
            actual = obj.InputRate;
            try
                [~, actual] = LabJack.LJM.eStreamStart(obj.Handle, ...
                    obj.BlockSize, nCh, obj.ScanAddresses, actual);
            catch ME
                error('FlimirDaqLabJack:streamStartFailed', ...
                    ['Could not start the stream at %g Hz on %d channels ' ...
                     '(%g kSamples/s aggregate). The T7 tops out near 100 ' ...
                     'kSamples/s.\n\n%s'], obj.InputRate, nCh, ...
                    obj.InputRate * nCh / 1000, ME.message);
            end
            if abs(actual - obj.InputRate) > 0.01 * obj.InputRate
                warning('FlimirDaqLabJack:rateAdjusted', ...
                    'Requested %g Hz, device is running at %g Hz.', ...
                    obj.InputRate, actual);
            end
            obj.InputRate = actual;
            obj.Streaming = true;

            % eStreamRead blocks until a full block is available, so the
            % timer paces itself against the device clock.  The period is
            % set a little short so the callback is always waiting on data
            % rather than the data waiting on the callback.
            period = obj.BlockSize / obj.InputRate;
            obj.InputTimer = timer( ...
                'ExecutionMode', 'fixedSpacing', ...
                'Period', max(0.01, round(period * 0.8, 3)), ...
                'BusyMode', 'drop', ...
                'TimerFcn', @(~, ~) obj.drainStream());
            start(obj.InputTimer);
        end

        function stopInput(obj)
            if ~isempty(obj.InputTimer) && isvalid(obj.InputTimer)
                try
                    stop(obj.InputTimer);
                catch
                end
                delete(obj.InputTimer);
            end
            obj.InputTimer = [];
            if obj.Streaming
                try
                    LabJack.LJM.eStreamStop(obj.Handle);
                catch
                end
                obj.Streaming = false;
            end
        end

        % --- software-timed outputs -----------------------------------
        function openOutputs(obj)
            obj.ensureOpen();
            obj.OutputsOpen = true;
            obj.writeOutputs(0, 0, false);
        end

        function writeOutputs(obj, laserVolts, phaseVolts, shutterOpen)
            if ~obj.OutputsOpen
                error('FlimirDaqLabJack:noOutput', 'Call openOutputs first.');
            end
            laserVolts = obj.clampDac(laserVolts);
            phaseVolts = obj.clampDac(phaseVolts);

            names = NET.createArray('System.String', 3);
            names(1) = obj.laserOutputChannel();
            names(2) = obj.phaseOutputChannel();
            names(3) = obj.shutterOutputChannel();
            values = NET.createArray('System.Double', 3);
            values(1) = laserVolts;
            values(2) = phaseVolts;
            values(3) = double(logical(shutterOpen));

            errAddr = 0;
            [~, errAddr] = LabJack.LJM.eWriteNames(obj.Handle, 3, names, ...
                values, errAddr); %#ok<ASGLU>
        end

        function zeroOutputs(obj)
            try
                if obj.Handle == 0
                    obj.ensureOpen();
                end
                obj.OutputsOpen = true;
                obj.writeOutputs(obj.LaserOffVolts, 0, false);
            catch ME
                warning('FlimirDaqLabJack:zeroOutputsFailed', ...
                    'Could not return the DACs to 0 V: %s', ME.message);
            end
        end

        % --- clocked, synchronised sweep -------------------------------
        function [ai, nFilled] = runClockedSweep(obj, inputChannels, rate, ...
                outputScans, openShutter, onBlock, stopFcn)
        % The phase ramp is emitted by the T7's stream-out engine, which
        % clocks it from the same timebase as the analog input scan, and
        % the inputs are streamed back in the usual way.
        %
        % The laser channel is written once rather than streamed: it is a
        % DC hold for the whole sweep (the waveform's laser column is
        % constant apart from the closing tail), so a second stream-out
        % buffer would buy nothing.

            obj.ensureOpen();
            obj.stopInput();     % the sweep needs the channels to itself

            nScans = size(outputScans, 1);
            nCh = numel(inputChannels);
            ai = nan(nScans, nCh);
            nFilled = 0;

            if nScans > FlimirDaqLabJack.STREAM_OUT_MAX_VALUES
                error('FlimirDaqLabJack:sweepTooLong', ...
                    ['This sweep is %d scans; the T7 stream-out buffer ' ...
                     'holds %d. Lower the sample rate or shorten the ' ...
                     'sweep.'], nScans, ...
                     FlimirDaqLabJack.STREAM_OUT_MAX_VALUES);
            end

            streamStarted = false;
            outEnabled = false;

            % Explicit teardown on both paths, for the same reason as the
            % NI backend: onCleanup runs too late to read these reliably.
            try
                runSweep();
            catch ME
                shutDown();
                rethrow(ME);
            end
            shutDown();

            % -----------------------------------------------------------
            function runSweep()
                laserVolts = obj.clampDac(outputScans(1, 1));
                phase = min(max(outputScans(:, 2), 0), ...
                    FlimirDaqLabJack.DAC_CEILING);

                % Laser and shutter are held for the duration
                names = NET.createArray('System.String', 2);
                names(1) = obj.laserOutputChannel();
                names(2) = obj.shutterOutputChannel();
                values = NET.createArray('System.Double', 2);
                values(1) = laserVolts;
                values(2) = double(logical(openShutter));
                ea = 0;
                [~, ea] = LabJack.LJM.eWriteNames(obj.Handle, 2, names, ...
                    values, ea); %#ok<ASGLU>

                % Load the phase ramp into the stream-out buffer
                dacAddr = obj.addressOf(obj.phaseOutputChannel());
                wave = NET.createArray('System.Double', nScans);
                for i = 1:nScans
                    wave(i) = phase(i);
                end
                LabJack.LJM.PeriodicStreamOut(obj.Handle, 0, dacAddr, ...
                    rate, nScans, wave);
                outEnabled = true;

                % STREAM_OUT0 has to be in the scan list or the stream-out
                % engine never advances and the DAC just sits at its last
                % value.  It does not, however, come back as data.  That
                % leaves the read buffer larger than the data in it:
                % eStreamRead insists the array is scansPerRead by the
                % number of scan-list addresses, but only the first
                % scansPerRead*nCh values are written and the tail is
                % left holding whatever was there before.  Reshaping the
                % whole array mixes that stale tail into the record, so
                % only the populated head is used below.
                %
                % Verified on the T7 with DC markers on a two-channel
                % scan list: with STREAM_OUT0 appended the samples still
                % alternate with period two, and AIN5 reads the streamed
                % constant rather than the static one.
                ids = [{inputChannels.id}, {'STREAM_OUT0'}];
                addrs = obj.namesToAddresses(ids);
                nAddresses = nCh + 1;
                scansPerRead = max(1, min(round(rate * 0.1), nScans));
                % The stream-out was configured at the requested rate, so
                % the input must run at it too; report if it could not
                actual = rate;
                [~, actual] = LabJack.LJM.eStreamStart(obj.Handle, ...
                    scansPerRead, nAddresses, addrs, actual);
                streamStarted = true;
                if abs(actual - rate) > 0.01 * rate
                    warning('FlimirDaqLabJack:sweepRateAdjusted', ...
                        ['Sweep requested %g Hz but the device is running ' ...
                         'at %g Hz; the phase ramp and the input scan are ' ...
                         'no longer on the same timebase.'], rate, actual);
                end

                % Buffer sized by address count; only the head is filled
                nValues = scansPerRead * nCh;
                data = NET.createArray('System.Double', scansPerRead * nAddresses);
                while nFilled < nScans
                    if stopFcn()
                        break;
                    end
                    b1 = 0; b2 = 0;
                    [~, b1, b2] = LabJack.LJM.eStreamRead(obj.Handle, ...
                        data, b1, b2); %#ok<ASGLU>
                    raw = double(data);
                    block = reshape(raw(1:nValues), nCh, [])';
                    m = min(size(block, 1), nScans - nFilled);
                    ai(nFilled + (1:m), :) = block(1:m, :);
                    nFilled = nFilled + m;
                    onBlock(ai, nFilled);
                    drawnow limitrate;
                end
            end

            function shutDown()
                if streamStarted
                    try
                        LabJack.LJM.eStreamStop(obj.Handle);
                    catch
                    end
                    streamStarted = false;
                end
                if outEnabled
                    % Leave the stream-out engine disabled, or it keeps
                    % driving the DAC into the next acquisition
                    try
                        LabJack.LJM.eWriteName(obj.Handle, ...
                            'STREAM_OUT0_ENABLE', 0);
                    catch
                    end
                    outEnabled = false;
                end
                obj.OutputsOpen = true;   % zeroOutputs writes through this
                obj.zeroOutputs();
            end
        end

        % --- teardown --------------------------------------------------
        function closeDevice(obj)
            obj.stopInput();
            try
                if obj.Handle ~= 0 && obj.OutputsOpen
                    obj.writeOutputs(0, 0, false);
                end
            catch
            end
            obj.OutputsOpen = false;
            obj.OnBlock = [];
            if obj.Handle ~= 0
                try
                    LabJack.LJM.Close(obj.Handle);
                catch
                end
                obj.Handle = 0;
            end
        end
    end

    % ---------------------------------------------------------------------
    methods (Access = private)
        function ensureOpen(obj)
            if obj.Handle ~= 0
                return;
            end
            if ~FlimirDaqLabJack.loadAssembly()
                error('FlimirDaqLabJack:noLJM', ...
                    ['The LJM .NET assembly could not be loaded. Install ' ...
                     'the LabJack LJM software.']);
            end
            h = 0;
            [err, h] = LabJack.LJM.OpenS('T7', 'USB', obj.DeviceID, h);
            if int32(err) ~= 0
                error('FlimirDaqLabJack:openFailed', ...
                    'Could not open T7 "%s" (LJM error %s).', ...
                    obj.DeviceID, char(err.ToString()));
            end
            obj.Handle = h;
        end

        function addr = addressOf(obj, name)
            a = obj.namesToAddresses({name});
            addr = int32(a(1));
        end

        function addresses = namesToAddresses(obj, ids)
            n = numel(ids);
            names = NET.createArray('System.String', n);
            for i = 1:n
                names(i) = ids{i};
            end
            addresses = NET.createArray('System.Int32', n);
            types = NET.createArray('System.Int32', n);
            try
                LabJack.LJM.NamesToAddresses(n, names, addresses, types);
            catch ME
                error('FlimirDaqLabJack:badChannel', ...
                    'The T7 does not recognise one of these channels (%s):\n%s', ...
                    strjoin(ids, ', '), ME.message);
            end
            obj.assertKnown(ids, addresses);
        end

        function assertKnown(~, ids, addresses)
            a = int32(addresses);
            bad = ids(a < 0);
            if ~isempty(bad)
                error('FlimirDaqLabJack:badChannel', ...
                    'Unknown T7 channel name(s): %s', strjoin(bad, ', '));
            end
        end

        function v = clampDac(~, v)
            % The DACs saturate a little under 5 V; clamping here keeps
            % the commanded and actual levels honest
            v = min(max(v, 0), FlimirDaqLabJack.DAC_CEILING);
        end

        function drainStream(obj)
            if ~obj.Streaming || isempty(obj.OnBlock)
                return;
            end
            nCh = numel(obj.InputChannels);
            data = NET.createArray('System.Double', obj.BlockSize * nCh);
            devBacklog = 0;
            ljmBacklog = 0;
            try
                [~, devBacklog, ljmBacklog] = LabJack.LJM.eStreamRead( ...
                    obj.Handle, data, devBacklog, ljmBacklog); %#ok<ASGLU>
            catch ME
                fprintf('LabJack stream read failed: %s\n', ...
                    strtok(ME.message, newline));
                return;
            end
            % LJM hands back one interleaved block: scan-major, channel
            % within scan, which is the transpose of what the app wants
            block = reshape(double(data), nCh, [])';
            obj.OnBlock(block);
        end
    end
end
