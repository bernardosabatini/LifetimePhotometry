classdef FlimirDaqDevice < handle
%FLIMIRDAQDEVICE  What FLIMIR needs from a data acquisition device.
%
%   This is deliberately not a general purpose DAQ wrapper.  It is the
%   narrow set of operations the FLIMIR application performs, expressed so
%   that no vendor syntax leaks into the GUI, the calibration routine or
%   the analysis code.  Swapping National Instruments for a LabJack (or a
%   simulator) means writing one subclass and nothing else.
%
%   Shipped implementations:
%       FlimirDaqNI          National Instruments, via Data Acquisition Toolbox
%       FlimirDaqSimulated   synthetic signals, no hardware required
%
%   To add a backend, subclass this and implement every abstract member.
%   flimir_daq_backends() discovers subclasses automatically, so a new
%   class placed on the path appears in the app's Backend menu with no
%   other change.
%
%   THE FOUR THINGS A BACKEND MUST DO
%
%   1. Name its channels.  The app never writes 'ai0' or 'DAC0' itself; it
%      asks the device.  defaultInputChannels/laserOutputChannel/
%      phaseOutputChannel/shutterOutputChannel supply the vendor's spelling.
%
%   2. Stream input continuously.  openInput/startInput/stopInput, handing
%      each block of samples to a callback as an nSamples-by-nChannels
%      matrix of doubles.
%
%   3. Hold software-timed outputs.  openOutputs/writeOutputs sets the
%      laser level, the phase shifter level and the shutter line.
%
%   4. Run a clocked sweep.  runClockedSweep generates a preloaded output
%      waveform while recording the inputs on the same clock, streaming
%      partial results so the calibration monitor can fill in live.  A
%      backend that cannot do this overrides supportsClockedSweep to
%      return false, and the app disables calibration for it.
%
%   See also FLIMIRDAQNI, FLIMIRDAQSIMULATED, FLIMIR_DAQ_BACKENDS.

    properties (SetAccess = protected)
        DeviceID = ''     % vendor device identifier, e.g. 'Dev1'
    end

    properties
        % The output level that means "laser off".
        %
        % Normally 0 V, but some laser controllers invert: full scale is
        % off and 0 V is maximum power.  Every path that parks the
        % hardware - zeroOutputs, the end of a run, the tail of a
        % calibration waveform - has to drive THIS level rather than a
        % hard-coded zero, or "make safe" turns the laser fully on.
        % The application sets it to match the control it is driving.
        LaserOffVolts = 0
    end

    % ---------------------------------------------------------------------
    methods (Abstract, Static)
        % Human readable backend name for the UI, e.g. 'National Instruments'
        name = backendName()

        % Discover attached devices.  Returns a struct array with fields
        % 'id' and 'description'; empty struct array when none are found.
        % Must not throw when the vendor's toolbox is absent - return empty.
        devices = listDevices()
    end

    % ---------------------------------------------------------------------
    methods (Abstract)
        % --- channel naming -------------------------------------------
        % The n analog inputs the FLIM computation always needs, in order:
        % the four mixer channels then the DC/intensity channel.
        ids = defaultInputChannels(obj, n)
        id = laserOutputChannel(obj)      % analog out, laser power
        id = phaseOutputChannel(obj)      % analog out, phase shifter
        id = shutterOutputChannel(obj)    % digital out, shutter TTL

        % --- continuous input -----------------------------------------
        % channels : struct array with fields 'id' and 'type'
        %            ('Analog' | 'Digital')
        % rate     : samples per second
        % blockSize: samples per callback
        % onBlock  : called as onBlock(data), data nSamples-by-nChannels
        openInput(obj, channels, rate, blockSize, onBlock)
        startInput(obj)
        stopInput(obj)

        % --- software-timed outputs -----------------------------------
        openOutputs(obj)
        writeOutputs(obj, laserVolts, phaseVolts, shutterOpen)

        % Force both analog outputs to 0 V and close the shutter, even if
        % no output session is currently open.  Must not throw.
        zeroOutputs(obj)

        % --- clocked, synchronised output + input ---------------------
        % outputScans : nScans-by-2, columns [laser, phaseShifter] in volts
        % onBlock     : onBlock(aiBuffer, nFilled) as samples accumulate
        % stopFcn     : called each poll; returning true aborts the sweep
        % Returns the full nScans-by-nChannels input buffer (unfilled rows
        % NaN) and how many scans were actually recorded.
        [ai, nFilled] = runClockedSweep(obj, inputChannels, rate, ...
            outputScans, openShutter, onBlock, stopFcn)

        % --- teardown --------------------------------------------------
        % Release every task.  Must be safe to call repeatedly.
        closeDevice(obj)
    end

    % ---------------------------------------------------------------------
    methods
        function tf = supportsClockedSweep(~)
            % Override and return false on hardware that cannot generate a
            % hardware-clocked output synchronised with its input.
            tf = true;
        end

        function range = outputVoltageRange(~)
            % What the analog outputs can actually reach, [min max].  The
            % calibration clips its ramp to this, so a board that cannot
            % drive the full phase shifter range sweeps as far as it can
            % and says so rather than silently saturating.
            range = [0 10];
        end

        function n = maxSweepScans(~)
            % Longest clocked sweep the device can emit, in scans.  A
            % board that streams its output from a bounded buffer reports
            % that bound here and the caller lowers the sweep's sample
            % rate to fit.  Unlimited by default.
            n = Inf;
        end

        function mc = knownCalibration(~)
            % A device that already knows its own mixer calibration
            % returns it here, in the form calculate_tau_s_g expects; the
            % app adopts it on selection so lifetime and phasor work
            % immediately.  Real hardware cannot know this - it has to be
            % measured with a sweep - so the default is empty.  The
            % simulator overrides it with the ground truth of its own
            % forward model.
            mc = [];
        end

        function ids = reservedChannels(obj)
            % Channels the fixed configuration already consumes, so the
            % app can refuse to add them again as extra inputs.
            ids = [obj.defaultInputChannels(5), ...
                   {obj.laserOutputChannel(), obj.phaseOutputChannel(), ...
                    obj.shutterOutputChannel()}];
        end

        function ids = suggestExtraChannel(obj, channelType, used)
            % Lowest unused channel of the requested type.  Backends with
            % different numbering can override; this covers the common
            % '<prefix><n>' case by reusing the default channel naming.
            used = [used(:); obj.reservedChannels()'];
            if strcmpi(channelType, 'Analog')
                template = obj.defaultInputChannels(1);
                template = template{1};
                startIdx = 5;
            else
                template = obj.shutterOutputChannel();
                startIdx = 1;
            end
            [prefix, ~] = splitTrailingNumber(template);
            for k = startIdx:64
                ids = sprintf('%s%d', prefix, k);
                if ~any(strcmpi(ids, used))
                    return;
                end
            end
            ids = sprintf('%s%d', prefix, startIdx);
        end

        function delete(obj)
            try
                obj.closeDevice();
            catch
                % teardown must never throw from a destructor
            end
        end
    end
end

% =========================================================================

function [prefix, number] = splitTrailingNumber(name)
    tok = regexp(name, '^(.*?)(\d+)$', 'tokens', 'once');
    if isempty(tok)
        prefix = name;
        number = 0;
    else
        prefix = tok{1};
        number = str2double(tok{2});
    end
end
