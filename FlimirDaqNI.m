classdef FlimirDaqNI < FlimirDaqDevice
%FLIMIRDAQNI  National Instruments backend, via the Data Acquisition Toolbox.
%
%   dev = FlimirDaqNI('Dev1')
%
%   Every call into daq(), addinput/addoutput, read/write, preload/start
%   for NI hardware lives in this class.  Nothing above it knows the
%   toolbox exists.
%
%   See also FLIMIRDAQDEVICE, FLIMIRDAQSIMULATED.

    properties (Access = private)
        InputTask = []      % continuous input DataAcquisition
        OutputTask = []     % software-timed output DataAcquisition
        OnBlock = []        % callback for streamed input blocks
        InputBlockSize = 0
    end

    % ---------------------------------------------------------------------
    methods (Static)
        function name = backendName()
            name = 'National Instruments';
        end

        function devices = listDevices()
            devices = struct('id', {}, 'description', {});
            try
                list = daqlist("ni");
            catch
                return;   % toolbox or driver absent - report nothing
            end
            for i = 1:height(list)
                devices(end+1).id = char(string(list.DeviceID(i))); %#ok<AGROW>
                devices(end).description = char(string(list.Description(i)));
            end
        end
    end

    % ---------------------------------------------------------------------
    methods
        function obj = FlimirDaqNI(deviceID)
            obj.DeviceID = char(string(deviceID));
        end

        % --- channel naming -------------------------------------------
        function ids = defaultInputChannels(~, n)
            ids = arrayfun(@(k) sprintf('ai%d', k), 0:n-1, ...
                'UniformOutput', false);
        end

        function id = laserOutputChannel(~);   id = 'ao0';          end
        function id = phaseOutputChannel(~);   id = 'ao1';          end
        function id = shutterOutputChannel(~); id = 'port0/line0';  end

        % --- continuous input -----------------------------------------
        function openInput(obj, channels, rate, blockSize, onBlock)
            obj.closeInput();

            d = daq("ni");
            for i = 1:numel(channels)
                if strcmpi(channels(i).type, 'Digital')
                    addinput(d, obj.DeviceID, channels(i).id, "Digital");
                else
                    addinput(d, obj.DeviceID, channels(i).id, "Voltage");
                end
            end
            d.Rate = rate;
            d.ScansAvailableFcnCount = max(1, round(blockSize));
            d.ScansAvailableFcn = @(src, ~) obj.deliverBlock(src);

            obj.InputTask = d;
            obj.OnBlock = onBlock;
            obj.InputBlockSize = d.ScansAvailableFcnCount;
        end

        function startInput(obj)
            if isempty(obj.InputTask)
                error('FlimirDaqNI:noInput', 'Call openInput first.');
            end
            start(obj.InputTask, "continuous");
        end

        function stopInput(obj)
            if ~isempty(obj.InputTask) && isvalid(obj.InputTask)
                try
                    stop(obj.InputTask);
                catch
                end
            end
        end

        % --- software-timed outputs -----------------------------------
        function openOutputs(obj)
            obj.closeOutputs();
            d = daq("ni");
            % Order matters: writeOutputs supplies [laser, phase, shutter]
            addoutput(d, obj.DeviceID, obj.laserOutputChannel(), "Voltage");
            addoutput(d, obj.DeviceID, obj.phaseOutputChannel(), "Voltage");
            addoutput(d, obj.DeviceID, obj.shutterOutputChannel(), "Digital");
            obj.OutputTask = d;
            obj.writeOutputs(0, 0, false);   % park in a known state
        end

        function writeOutputs(obj, laserVolts, phaseVolts, shutterOpen)
            if isempty(obj.OutputTask) || ~isvalid(obj.OutputTask)
                error('FlimirDaqNI:noOutput', 'Call openOutputs first.');
            end
            write(obj.OutputTask, [laserVolts, phaseVolts, double(shutterOpen)]);
        end

        function zeroOutputs(obj)
            % Works whether or not an output session is open: if one is,
            % use it; otherwise create a throwaway task.  Retried once,
            % because a task that has only just been deleted can briefly
            % still hold its channels.
            if ~isempty(obj.OutputTask) && isvalid(obj.OutputTask)
                try
                    obj.writeOutputs(obj.LaserOffVolts, 0, false);
                    return;
                catch
                end
            end
            for attempt = 1:2
                try
                    dz = daq("ni");
                    addoutput(dz, obj.DeviceID, obj.laserOutputChannel(), "Voltage");
                    addoutput(dz, obj.DeviceID, obj.phaseOutputChannel(), "Voltage");
                    write(dz, [obj.LaserOffVolts 0]);
                    delete(dz);
                    break;
                catch ME
                    if attempt == 2
                        warning('FlimirDaqNI:zeroOutputsFailed', ...
                            'Could not return the analog outputs to 0 V: %s', ...
                            ME.message);
                    else
                        pause(0.2);
                    end
                end
            end
            obj.setShutter(false);
        end

        % --- clocked, synchronised sweep -------------------------------
        function [ai, nFilled] = runClockedSweep(obj, inputChannels, rate, ...
                outputScans, openShutter, onBlock, stopFcn)

            % The sweep needs the same analog inputs and outputs the
            % streaming session holds, and NI will refuse to reserve them
            % twice.  Release ours first rather than relying on the caller
            % having done it.
            obj.closeDevice();

            nScans = size(outputScans, 1);
            nCh = numel(inputChannels);
            ai = nan(nScans, nCh);
            nFilled = 0;

            d = [];
            dShutter = [];

            % shutDown is called explicitly on both exit paths rather than
            % through onCleanup: onCleanup fires while the enclosing
            % workspace is already being torn down, so a nested cleanup
            % cannot reliably read the variables it needs.
            try
                runSweep();
            catch ME
                shutDown();
                rethrow(ME);
            end
            shutDown();

            % -----------------------------------------------------------
            function runSweep()
                if openShutter
                    dShutter = daq("ni");
                    addoutput(dShutter, obj.DeviceID, ...
                        obj.shutterOutputChannel(), "Digital");
                    write(dShutter, 1);
                end

                d = daq("ni");
                addoutput(d, obj.DeviceID, obj.laserOutputChannel(), "Voltage");
                addoutput(d, obj.DeviceID, obj.phaseOutputChannel(), "Voltage");
                for i = 1:nCh
                    if strcmpi(inputChannels(i).type, 'Digital')
                        addinput(d, obj.DeviceID, inputChannels(i).id, "Digital");
                    else
                        addinput(d, obj.DeviceID, inputChannels(i).id, "Voltage");
                    end
                end
                d.Rate = rate;
                d.ScansAvailableFcnCount = max(1, round(rate * 0.1));
                d.ScansAvailableFcn = @(src, ~) drainInput(src);

                preload(d, outputScans);
                start(d);

                deadline = tic;
                timeout = nScans / rate + 10;
                aborted = false;
                while d.Running
                    if stopFcn()
                        aborted = true;
                        break;
                    end
                    if toc(deadline) > timeout
                        error('FlimirDaqNI:sweepTimeout', ...
                            'Sweep did not finish within %.0f s.', timeout);
                    end
                    drawnow limitrate;
                end

                if aborted
                    % Aborting halts the generation wherever it happens to
                    % be, which on the laser channel is mid-power.  Stop
                    % and zero here rather than after draining.
                    try
                        stop(d);
                    catch
                    end
                    closeShutterTask();
                    try
                        delete(d);
                        d = [];
                    catch
                    end
                    obj.zeroOutputs();
                end

                drainInput(d);
            end

            function drainInput(src)
                if isempty(src) || ~isvalid(src)
                    return;
                end
                try
                    n = src.NumScansAvailable;
                catch
                    return;   % task already torn down
                end
                if n < 1
                    return;
                end
                chunk = read(src, n, "OutputFormat", "Matrix");
                m = min(size(chunk, 1), nScans - nFilled);
                if m < 1
                    return;
                end
                ai(nFilled + (1:m), :) = chunk(1:m, :);
                nFilled = nFilled + m;
                onBlock(ai, nFilled);
            end

            function closeShutterTask()
                try
                    if ~isempty(dShutter) && isvalid(dShutter)
                        write(dShutter, 0);
                    end
                catch
                end
            end

            function shutDown()
                try
                    if ~isempty(d) && isvalid(d)
                        stop(d);
                        delete(d);
                    end
                catch
                end
                d = [];
                obj.zeroOutputs();
                closeShutterTask();
                try
                    if ~isempty(dShutter) && isvalid(dShutter)
                        delete(dShutter);
                    end
                catch
                end
                dShutter = [];
            end
        end

        % --- teardown --------------------------------------------------
        function closeDevice(obj)
            obj.closeInput();
            obj.closeOutputs();
        end
    end

    % ---------------------------------------------------------------------
    methods (Access = private)
        function deliverBlock(obj, src)
            if isempty(obj.OnBlock)
                return;
            end
            data = read(src, src.ScansAvailableFcnCount, "OutputFormat", "Matrix");
            obj.OnBlock(data);
        end

        function setShutter(obj, isOpen)
            if ~isempty(obj.OutputTask) && isvalid(obj.OutputTask)
                return;   % already handled by writeOutputs
            end
            try
                ds = daq("ni");
                addoutput(ds, obj.DeviceID, obj.shutterOutputChannel(), "Digital");
                write(ds, double(isOpen));
                delete(ds);
            catch
                % shutter may be in use by another task; not fatal
            end
        end

        function closeInput(obj)
            if ~isempty(obj.InputTask)
                try
                    stop(obj.InputTask);
                catch
                end
                try
                    delete(obj.InputTask);
                catch
                end
                obj.InputTask = [];
            end
            obj.OnBlock = [];
        end

        function closeOutputs(obj)
            if ~isempty(obj.OutputTask)
                try
                    stop(obj.OutputTask);
                catch
                end
                try
                    delete(obj.OutputTask);
                catch
                end
                obj.OutputTask = [];
            end
        end
    end
end
