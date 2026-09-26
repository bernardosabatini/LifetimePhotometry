classdef FlimirDaqSimulated < FlimirDaqDevice
%FLIMIRDAQSIMULATED  A working FLIM rig in software, no hardware required.
%
%   dev = FlimirDaqSimulated('Sim1')
%
%   Synthesises the five analog inputs from an explicit forward model of
%   frequency-domain FLIM with four-phase homodyne detection, so the whole
%   application - acquisition, calibration, the phase fit and the
%   per-block lifetime estimate - closes the loop with nothing attached.
%
%   THE MODEL
%
%   A sample whose fluorescence lifetime is tau, excited by light
%   modulated at omega, emits light that is phase delayed and demodulated:
%
%       phi_tau(tau) = atan(omega * tau)
%       m(tau)       = 1 / sqrt(1 + (omega*tau)^2)
%
%   The detected fluorescence is split four ways and each copy is
%   multiplied by a reference (local oscillator) carrying one of four
%   phase shifts - nominally 0, pi/2, pi and 3*pi/2.  The reference has
%   been adjusted by the phase shifter so that the 0-phase copy lines up
%   with the fluorescence of the calibration sample.  Low-pass filtering
%   each product leaves a DC term
%
%       VIF_i = o_i + k_i * A * m(tau)/m(tauCal)
%                         * sin( phi_i + theta_V + phi_tau(tau) )
%       VDC   = intensity
%
%   with phi_i the four reference phases, theta_V the extra phase the
%   shifter contributes at the current control voltage, and the modulation
%   referenced to the calibration lifetime so a tauCal sample gives unit
%   amplitude.  This is exactly the model calculate_phase_calibration
%   fits, so a calibration taken from the simulator feeds straight back
%   into calculate_tau_s_g and returns the lifetime that went in.
%
%   THE SAMPLE: A MOLECULE WITH TWO STATES
%
%   The molecule sits in one of two states, each with its own lifetime
%   and brightness:
%
%       state 1:  tau = 2 ns,  intensity 1
%       state 2:  tau = 3 ns,  intensity 5
%
%   An Ornstein-Uhlenbeck process - a Gaussian process with exponential
%   autocorrelation and a 1 s correlation time by default - drives the
%   fraction f in state 2, through a logistic map that keeps it inside
%   (0,1).  The OU state is carried across blocks, so the trace is
%   continuous rather than resetting at every callback.
%
%   Two species do not give a single exponential.  Their phasors add,
%   weighted by how much light each contributes:
%
%       a_k  = f_k * I_k / sum(f * I)          intensity fractions
%       g_k  = 1/(1+(w*tau_k)^2)
%       s_k  = w*tau_k/(1+(w*tau_k)^2)
%       G,S  = sum(a_k * g_k), sum(a_k * s_k)
%
%   so the mixture's phasor lands on the chord between the two
%   single-exponential points, inside the universal semicircle, and the
%   phase lifetime the app recovers sits between 2 and 3 ns.  Because
%   state 2 is five times brighter, the total intensity swings by 5x as
%   the fraction moves, and lifetime and intensity are correlated.
%
%   During a calibration sweep the sample is replaced by a single
%   exponential reference dye of lifetime CalibrationLifetime: you
%   calibrate against a known standard, not a moving two-state mixture.
%
%   Fluorescence is proportional to excitation, so it scales with the
%   laser output and vanishes when the shutter is closed - at 0 V laser
%   power the mixer channels collapse to their offsets and VDC drops to
%   its dark level, exactly as the real rig would.
%
%   Tune any of it through the public properties:
%       dev.StateLifetimes  = [2e-9 3e-9];
%       dev.StateIntensities = [1 5];
%       dev.FractionTau = 0.5;   dev.PhaseSlope = 0.55;
%
%   See also FLIMIRDAQDEVICE, FLIMIRDAQNI, CALCULATE_TAU_S_G.

    properties
        % --- the two-state sample ---------------------------------------
        StateLifetimes      = [2e-9, 3e-9]   % lifetime of each state (s)
        StateIntensities    = [1, 5]         % brightness of each state
        FractionMean        = 0.5     % mean fraction in state 2
        FractionSpread      = 1.2     % how far the process swings it (logit)
        FractionTau         = 1.0     % correlation time of the wander (s)
        CalibrationLifetime = 2.4e-9  % single-exponential reference dye
        CalibrationIntensity = 3      % and how bright that dye is.  Every
                                      % amplitude is referenced to this, so
                                      % the reference does not move when the
                                      % sample's mixture is changed.

        % --- the optics and electronics ---------------------------------
        LaserFreq     = 50e6          % modulation frequency (Hz)
        LaserRefVolts = 2.0           % laser level giving nominal amplitude
        NominalPhases = [0; pi/2; pi; 3*pi/2]   % the four reference phases
        PhaseErrors   = [0.05; -0.03; 0.02; 0.04]  % real hardware is not exact
        ChannelGains  = [1.00 0.90 1.10 0.95]
        ChannelOffsets = [0.02 -0.01 0.03 0.00]
        Amplitude     = 0.80          % mixer output at unit modulation (V)
        PhaseSlope    = 0.55          % shifter phase per volt (rad/V)

        % --- the detector -----------------------------------------------
        DcGain        = 0.33          % VDC volts per unit intensity
        DcDark        = 0.02          % VDC with no light (V)
        NoiseVolts    = 5e-4

        % --- the patch panel --------------------------------------------
        % Which analog input the phase shifter output is patched back
        % into, modelling the loopback wire the user runs on real
        % hardware.  A device cannot know about a physical jumper, so the
        % simulator has to be told about it the same way; set it empty to
        % simulate a rig with no monitor wire, in which case the channel
        % reads the laser command like any other spare input.
        PhaseMonitorChannel = 'ai5'
        MonitorLagScans     = 1       % AO-to-AI pipeline delay, measured
                                      % as 1 scan on both the NI and T7
    end

    properties (Access = private)
        InputChannels = []
        InputRate = 1000
        BlockSize = 100
        OnBlock = []
        InputTimer = []
        LaserVolts = 0
        PhaseVolts = 0
        ShutterOpen = false
        MonitorColumn = []    % index of PhaseMonitorChannel in the scan
        MonitorHeld = 0       % last phase sample, carried across blocks
                              % so the loopback delay is continuous
        OutputsOpen = false
        FractionState = 0     % OU filter state, carried between blocks
    end

    % ---------------------------------------------------------------------
    methods (Static)
        function name = backendName()
            name = 'Simulated';
        end

        function devices = listDevices()
            devices = struct('id', {'Sim1'}, ...
                'description', {'Simulated FLIM rig (4-phase homodyne)'});
        end
    end

    % ---------------------------------------------------------------------
    methods
        function obj = FlimirDaqSimulated(deviceID)
            if nargin < 1 || isempty(deviceID)
                deviceID = 'Sim1';
            end
            obj.DeviceID = char(string(deviceID));
        end

        function phases = channelPhases(obj)
            phases = obj.NominalPhases(:) + obj.PhaseErrors(:);
        end

        function mc = knownCalibration(obj)
            % The ground truth of this simulator's own forward model,
            % handed over directly instead of being measured.  A sweep
            % against simulated hardware tells you nothing you did not
            % already put in, so the app adopts this on selection and
            % lifetime/phasor work from the first block.
            %
            % These are exactly the quantities calculate_tau_s_g divides
            % by, chosen so that its normalisation collapses to the
            % mixture phasor:
            %
            %   VIF_i  = o_i + A*k_i * exc * (Itot/Iref) * (m/mRef)
            %                        * sin(phi_i + theta_V + phi_mix)
            %   VDC    = dark + DcGain * exc * Itot
            %
            % Dividing VIF by AmpVIF_i = A*k_i and by VDC/meanVDC cancels
            % the excitation, the brightness and the gains, leaving
            % m*sin(phi_i + phi_mix) - which the phasor solve turns back
            % into the G and S that went in.
            omega = 2 * pi * obj.LaserFreq;
            amp = obj.Amplitude * obj.ChannelGains(:)';

            mc = struct();
            mc.phi_actual = obj.channelPhases();
            mc.max_VIF    =  amp;
            mc.min_VIF    = -amp;
            % The reference dye at unit excitation, above the dark level
            mc.meanVDC    = obj.DcGain * obj.CalibrationIntensity;
            mc.tau_bar    = obj.CalibrationLifetime;
            mc.omega      = omega;
            mc.laserFreq  = obj.LaserFreq;
            mc.offsetVIF  = obj.ChannelOffsets(:)';
            mc.offsetDC   = obj.DcDark;
            mc.k_est      = obj.ChannelGains(:);
            mc.o_est      = zeros(4, 1);
            mc.MoverB     = 1;
            mc.sourceRampSeconds = NaN;
            mc.sourceRate = NaN;
            mc.source     = 'built in to the Simulated backend';
            mc.timestamp  = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
        end

        % --- channel naming (mirrors NI so settings files interchange) --
        function ids = defaultInputChannels(~, n)
            ids = arrayfun(@(k) sprintf('ai%d', k), 0:n-1, ...
                'UniformOutput', false);
        end

        function id = laserOutputChannel(~);   id = 'ao0';          end
        function id = phaseOutputChannel(~);   id = 'ao1';          end
        function id = shutterOutputChannel(~); id = 'port0/line0';  end

        % --- continuous input -----------------------------------------
        function openInput(obj, channels, rate, blockSize, onBlock)
            obj.stopInput();
            obj.InputChannels = channels;
            obj.locateMonitor(channels);
            obj.InputRate = rate;
            obj.BlockSize = max(1, round(blockSize));
            obj.OnBlock = onBlock;
            obj.FractionState = 0;
        end

        function startInput(obj)
            if isempty(obj.OnBlock)
                error('FlimirDaqSimulated:noInput', 'Call openInput first.');
            end
            obj.stopInput();
            period = obj.BlockSize / obj.InputRate;
            obj.InputTimer = timer( ...
                'ExecutionMode', 'fixedSpacing', ...
                'Period', max(0.01, round(period, 3)), ...
                'BusyMode', 'drop', ...
                'TimerFcn', @(~, ~) obj.emitBlock());
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
        end

        % --- software-timed outputs -----------------------------------
        function openOutputs(obj)
            obj.OutputsOpen = true;
            obj.writeOutputs(0, 0, false);
        end

        function writeOutputs(obj, laserVolts, phaseVolts, shutterOpen)
            if ~obj.OutputsOpen
                error('FlimirDaqSimulated:noOutput', 'Call openOutputs first.');
            end
            obj.LaserVolts = laserVolts;
            obj.PhaseVolts = phaseVolts;
            obj.ShutterOpen = logical(shutterOpen);
        end

        function zeroOutputs(obj)
            % Through writeOutputs like the hardware backends, rather
            % than setting the fields behind its back: parking is the
            % same operation as any other write, and routing it the same
            % way keeps one place where the laser level is decided.
            obj.OutputsOpen = true;
            obj.writeOutputs(obj.LaserOffVolts, 0, false);
        end

        % --- clocked, synchronised sweep -------------------------------
        function [ai, nFilled] = runClockedSweep(obj, inputChannels, rate, ...
                outputScans, openShutter, onBlock, stopFcn)

            % Mirror the real backends: a sweep takes exclusive use of the
            % channels, so any streaming session is released first.
            obj.stopInput();

            obj.locateMonitor(inputChannels);

            nScans = size(outputScans, 1);
            nCh = numel(inputChannels);
            ai = nan(nScans, nCh);
            nFilled = 0;

            obj.ShutterOpen = logical(openShutter);
            blockSize = max(1, round(rate * 0.1));

            try
                tStart = tic;
                while nFilled < nScans
                    if stopFcn()
                        break;
                    end
                    m = min(blockSize, nScans - nFilled);
                    idx = nFilled + (1:m);
                    % A calibration measures the optics, so the sample is
                    % a single-exponential reference dye, not the moving
                    % two-state mixture
                    [G, S, Itot] = obj.referencePhasor(m);
                    ai(idx, :) = obj.synthesise(outputScans(idx, 1), ...
                        outputScans(idx, 2), nCh, G, S, Itot);
                    nFilled = nFilled + m;
                    onBlock(ai, nFilled);

                    % Run in something close to real time so the monitor
                    % behaves the way it will against real hardware
                    target = nFilled / rate;
                    while toc(tStart) < target
                        drawnow limitrate;
                    end
                end
            catch ME
                obj.zeroOutputs();
                rethrow(ME);
            end
            obj.zeroOutputs();
        end

        % --- teardown --------------------------------------------------
        function closeDevice(obj)
            obj.stopInput();
            obj.OutputsOpen = false;
            obj.OnBlock = [];
        end
    end

    % ---------------------------------------------------------------------
    methods (Access = private)
        function emitBlock(obj)
            n = obj.BlockSize;
            dt = 1 / obj.InputRate;

            % The Gaussian process drives the fraction in state 2, and
            % continues from where the previous block left off
            [x, obj.FractionState] = obj.advanceOU(obj.FractionState, ...
                n, dt, obj.FractionTau);
            f = obj.fractionFromProcess(x);

            [G, S, Itot] = obj.mixturePhasor(f);

            laser = repmat(obj.LaserVolts, n, 1);
            phase = repmat(obj.PhaseVolts, n, 1);
            data = obj.synthesise(laser, phase, ...
                numel(obj.InputChannels), G, S, Itot);
            if ~isempty(obj.OnBlock)
                obj.OnBlock(data);
            end
        end

        function f = fractionFromProcess(obj, x)
            % Logistic map of the Gaussian process onto (0,1), centred so
            % that x = 0 gives FractionMean
            centre = log(obj.FractionMean / (1 - obj.FractionMean));
            f = 1 ./ (1 + exp(-(centre + obj.FractionSpread * x(:))));
        end

        function [G, S, Itot] = mixturePhasor(obj, f)
            % Phasors of the two species add, weighted by the share of the
            % light each contributes.  The result sits on the chord
            % between the two single-exponential points.
            omega = 2 * pi * obj.LaserFreq;
            f = f(:);

            w1 = (1 - f) * obj.StateIntensities(1);
            w2 = f       * obj.StateIntensities(2);
            Itot = w1 + w2;
            a1 = w1 ./ Itot;
            a2 = w2 ./ Itot;

            wt1 = omega * obj.StateLifetimes(1);
            wt2 = omega * obj.StateLifetimes(2);
            g1 = 1 / (1 + wt1^2);   s1 = wt1 / (1 + wt1^2);
            g2 = 1 / (1 + wt2^2);   s2 = wt2 / (1 + wt2^2);

            G = a1 * g1 + a2 * g2;
            S = a1 * s1 + a2 * s2;
        end

        function [G, S, Itot] = referencePhasor(obj, n)
            % The single-exponential calibration dye, at the same average
            % brightness as the sample so amplitudes are comparable
            omega = 2 * pi * obj.LaserFreq;
            wt = omega * obj.CalibrationLifetime;
            G = repmat(1 / (1 + wt^2), n, 1);
            S = repmat(wt / (1 + wt^2), n, 1);
            Itot = repmat(obj.CalibrationIntensity, n, 1);
        end

        function data = synthesise(obj, laserVolts, phaseVolts, nCh, G, S, Itot)
            % Forward model shared by streaming and sweeps, driven by the
            % sample's phasor (G,S) and total intensity, so a calibration
            % taken from the simulator is consistent with what it reports.
            n = numel(phaseVolts);
            data = zeros(n, nCh);

            G = G(:); S = S(:); Itot = Itot(:);
            if isscalar(G),    G = repmat(G, n, 1);       end
            if isscalar(S),    S = repmat(S, n, 1);       end
            if isscalar(Itot), Itot = repmat(Itot, n, 1); end

            % Mixture phase and modulation depth, the latter referenced to
            % the calibration dye so a reference sample gives unit depth
            phiMix = atan2(S, G);
            mMix = hypot(G, S);
            omega = 2 * pi * obj.LaserFreq;
            mRef = 1 / sqrt(1 + (omega * obj.CalibrationLifetime)^2);
            depth = mMix / mRef;

            % Excitation: fluorescence follows the laser and stops dead
            % when the shutter is closed
            gate = double(obj.ShutterOpen);
            excitation = gate * max(0, laserVolts(:)) / obj.LaserRefVolts;

            % Brightness relative to the calibration dye, so the mixer
            % amplitude is nominal for a reference-brightness sample
            brightness = Itot / obj.CalibrationIntensity;

            thetaV = obj.PhaseSlope * phaseVolts(:);
            phases = obj.channelPhases();

            nMixer = min(4, nCh);
            for ch = 1:nMixer
                mixed = obj.Amplitude * obj.ChannelGains(ch) ...
                    * excitation .* brightness .* depth ...
                    .* sin(phases(ch) + thetaV + phiMix);
                data(:, ch) = obj.ChannelOffsets(ch) + mixed ...
                    + obj.NoiseVolts * randn(n, 1);
            end
            if nCh >= 5
                data(:, 5) = obj.DcDark ...
                    + obj.DcGain * excitation .* Itot ...
                    + obj.NoiseVolts * randn(n, 1);
            end
            % Any extra channels just carry the laser command plus noise
            for ch = 6:nCh
                data(:, ch) = laserVolts(:) + obj.NoiseVolts * randn(n, 1);
            end

            % The phase monitor is a wire, not a measurement: whatever
            % the shifter output was commanded to, delayed by the same
            % one scan the real boards show, plus the input's own noise.
            mc = obj.MonitorColumn;
            if ~isempty(mc) && mc <= nCh
                lag = max(0, round(obj.MonitorLagScans));
                pv = phaseVolts(:);
                if lag == 0
                    delayed = pv;
                else
                    delayed = [repmat(obj.MonitorHeld, min(lag, n), 1); ...
                               pv(1:max(0, n - lag))];
                    obj.MonitorHeld = pv(max(1, n - lag + 1));
                end
                data(:, mc) = delayed + obj.NoiseVolts * randn(n, 1);
            end
        end

        function locateMonitor(obj, channels)
            % Work out which scan column the loopback wire lands in.
            obj.MonitorColumn = [];
            obj.MonitorHeld = 0;
            if isempty(obj.PhaseMonitorChannel) || isempty(channels)
                return;
            end
            hit = find(strcmpi({channels.id}, obj.PhaseMonitorChannel), 1);
            if ~isempty(hit)
                obj.MonitorColumn = hit;
            end
        end
    end

    % ---------------------------------------------------------------------
    methods (Static, Access = private)
        function [x, state] = advanceOU(state, n, dt, correlationTime)
            % Ornstein-Uhlenbeck, sampled exactly:
            %   x[k] = a*x[k-1] + sqrt(1-a^2)*w[k],  a = exp(-dt/tauC)
            % Unit stationary variance and an exponential autocorrelation
            % with the requested correlation time.  filter() carries the
            % state, so successive blocks form one continuous process.
            if correlationTime <= 0
                x = randn(n, 1);
                state = 0;
                return;
            end
            a = exp(-dt / correlationTime);
            b = sqrt(max(0, 1 - a^2));
            [x, state] = filter(b, [1 -a], randn(n, 1), state);
        end
    end
end
