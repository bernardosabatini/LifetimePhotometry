classdef ThorlabsPMT < handle
%THORLABSPMT  Power and gain control for a Thorlabs PMT2100-series head.
%
%   p = ThorlabsPMT();          % open, using the default settings file
%   p.powerOn(30);              % enable at 30% gain
%   p.powerOff();               % disable
%   delete(p);                  % release the device
%
%   HOW THE SDK WORKS
%
%   Thorlabs ships a plain C DLL (ThorPMT2100.dll) with a parameter-based
%   API.  Nothing takes effect when you set it: SetParam only stages a
%   value, and the staged set is pushed to the hardware by the sequence
%
%       PreflightPosition -> SetupPosition -> StartPosition
%           -> poll StatusPosition until it is not STATUS_BUSY
%           -> PostflightPosition
%
%   Powering the PMT up and down is therefore SetParam of the ENABLE
%   parameter followed by that sequence, which is exactly what the
%   vendor's own PMT2100Test.cpp does.
%
%   WHY A .NET SHIM AND NOT loadlibrary
%
%   loadlibrary would need a C compiler configured through mex -setup to
%   parse the header and build a 64-bit thunk, and there is none on this
%   machine.  It also could not parse the vendor header regardless: the
%   prototypes use C++ reference parameters (long &DeviceCount), which
%   loadlibrary does not support.  ThorPmtShim.dll is a small P/Invoke
%   wrapper built with the csc.exe that ships with Windows, so it needs
%   nothing installed.  See ThorPmtShim.cs.
%
%   THE SETTINGS FILE
%
%   FindDevices returns 0 unless a ThorPMT2100Settings.xml listing the
%   head's serial number is in the *current working directory*.  The copy
%   in the SDK's bin\x64 folder has every slot set to "NA" and finds
%   nothing; the copy the GUI maintains under Application has the real
%   serial.  This class points the process at a known-good copy so the
%   caller's working directory does not matter.
%
%   ONE PROCESS AT A TIME
%
%   The head is a USBTMC device and the SDK claims it exclusively.  If
%   Thorlabs' own PMT2100_Control GUI is open, FindDevices here returns
%   no devices; close it first, and vice versa.
%
%   SAFETY
%
%   Enabling a PMT applies high voltage to the photocathode.  Exposing an
%   enabled PMT to room light can damage it and will trip the overcurrent
%   protection.  Block the light path before calling powerOn, and check
%   isTripped after any suspect exposure.
%
%   See also THORPMTSHIM.CS.

    properties (SetAccess = private)
        Serial    = ''     % USB serial of the head this object drives
        Slot      = 1      % PMT slot the serial was registered into
        IsOpen    = false
        DidEnable = false  % has this session ever commanded the HV on
        SdkDir    = 'C:\Program Files\Thorlabs\PMT2100 4.0\bin\x64'
        SettingsFile = ''  % ThorPMT2100Settings.xml actually used
    end

    properties (Constant, Access = private)
        % Parameter IDs are contiguous per slot for the first four slots
        GAIN_ID      = [700 702 704 706]
        ENABLE_ID    = [701 703 705 707]
        SAFETY_ID    = [713 714 715 716]
        BANDWIDTH_ID = [722 723 724 725]
        STATUS_BUSY  = 0
    end

    methods (Static)
        function devices = listDevices()
            %LISTDEVICES  Thorlabs PMT heads currently attached over USB.
            %
            %   Returns a struct array with fields 'id' (the USB serial)
            %   and 'description'.  Empty when none are attached; never
            %   throws, so a caller can offer the list unconditionally.
            %
            %   Enumerated from Windows' own device list rather than
            %   through the SDK, because the SDK cannot find a head until
            %   it has been told the serial - which is the thing we are
            %   trying to discover.
            devices = struct('id', {}, 'description', {});
            cmd = ['powershell -NoProfile -Command "Get-PnpDevice ' ...
                '-PresentOnly -ErrorAction SilentlyContinue | ' ...
                'Where-Object { $_.InstanceId -like ''USB\VID_1313*'' } | ' ...
                'ForEach-Object { $_.InstanceId + ''|'' + $_.FriendlyName }"'];
            [status, out] = system(cmd);
            if status ~= 0 || isempty(strtrim(out))
                return;
            end
            lines = strsplit(strtrim(out), newline);
            for k = 1:numel(lines)
                line = strtrim(lines{k});
                if isempty(line)
                    continue;
                end
                parts = strsplit(line, '|');
                idParts = strsplit(parts{1}, '\');
                serial = strtrim(idParts{end});
                if isempty(serial)
                    continue;
                end
                devices(end+1).id = serial; %#ok<AGROW>
                if numel(parts) > 1 && ~isempty(strtrim(parts{2}))
                    devices(end).description = sprintf('%s (%s)', ...
                        serial, strtrim(parts{2}));
                else
                    devices(end).description = serial;
                end
            end
        end
    end

    methods
        function obj = ThorlabsPMT(serial)
            %THORLABSPMT  Open the head with the given USB serial.
            %
            %   With no serial, the first attached head is used.
            if nargin < 1 || isempty(serial)
                found = ThorlabsPMT.listDevices();
                if isempty(found)
                    error('ThorlabsPMT:noneAttached', ...
                        'No Thorlabs PMT found on USB.');
                end
                serial = found(1).id;
            end
            obj.Serial = char(string(serial));
            here = fileparts(mfilename('fullpath'));

            % Write our own settings file rather than relying on the one
            % the vendor GUI maintains.  That file has to name the head's
            % serial or FindDevices reports nothing, and the copy shipped
            % in the SDK lists every slot as "NA".  Depending on whatever
            % the GUI last wrote also means the slot number - and so the
            % parameter IDs - changes out from under us.  Writing it here
            % puts the selected head in slot 1, every time.
            obj.SettingsFile = obj.writeSettingsFile(here, obj.Serial);
            obj.Slot = 1;

            NET.addAssembly(fullfile(here, 'ThorPmtShim.dll'));
            Thorlabs.Pmt.SetSdkDirectory(obj.SdkDir);

            % The DLL reads its settings file from the working directory,
            % so go there for the open and come straight back
            old = cd(fileparts(obj.SettingsFile));
            restore = onCleanup(@() cd(old));
            [ok, count] = Thorlabs.Pmt.FindDevices();
            if ok == 0 || count < 1
                error('ThorlabsPMT:notFound', ...
                    ['FindDevices found no PMT2100 with serial "%s". ' ...
                     'Check the head is connected and that Thorlabs'' ' ...
                     'own PMT2100_Control application is closed - it ' ...
                     'claims the head exclusively.'], obj.Serial);
            end
            if Thorlabs.Pmt.SelectDevice(0) == 0
                error('ThorlabsPMT:selectFailed', 'SelectDevice(0) failed.');
            end
            obj.IsOpen = true;
        end

        function powerOn(obj, gainPercent)
            %POWERON  Enable the PMT, optionally setting the gain first.
            %   Gain is staged before enable so the head never comes up at
            %   whatever gain was left over from a previous session.
            if nargin >= 2 && ~isempty(gainPercent)
                obj.stage(obj.GAIN_ID(obj.Slot), gainPercent);
            end
            obj.stage(obj.ENABLE_ID(obj.Slot), 1);
            obj.DidEnable = true;
            obj.apply();
        end

        function powerOff(obj)
            %POWEROFF  Disable the PMT.
            obj.stage(obj.ENABLE_ID(obj.Slot), 0);
            obj.apply();
        end

        function setGain(obj, gainPercent)
            %SETGAIN  Change gain, in percent, without touching enable.
            obj.stage(obj.GAIN_ID(obj.Slot), gainPercent);
            obj.apply();
        end

        function tf = isEnabled(obj)
            tf = obj.read(obj.ENABLE_ID(obj.Slot)) ~= 0;
        end

        function [tf, known] = isTripped(obj)
            %ISTRIPPED  Overcurrent protection status, where it can be read.
            %   [tf, known] = p.isTripped()
            %
            %   known is false when the SDK will not report it, and tf is
            %   then meaningless.  Check known before acting on tf.
            %
            %   This matters here: on this unit GetParam on the SAFETY
            %   parameter returns failure for every slot, populated or
            %   not, while leaving a 1 in the output.  Reading that as a
            %   trip is how an earlier version of this class talked itself
            %   into aborting a perfectly healthy run.  GetParamInfo does
            %   report the parameter as available and read-only, so the
            %   SDK knows about it; it just will not hand over the value
            %   outside whatever state makes it live.
            obj.assertOpen();
            [ok, v] = Thorlabs.Pmt.GetParam(obj.SAFETY_ID(obj.Slot));
            known = ok ~= 0;
            tf = known && v ~= 0;
        end

        function v = gain(obj)
            v = obj.read(obj.GAIN_ID(obj.Slot));
        end

        function info = paramInfo(obj, id)
            %PARAMINFO  Range and availability of a parameter, for probing.
            obj.assertOpen();
            [ok, type, avail, readOnly, mn, mx, def] = ...
                Thorlabs.Pmt.GetParamInfo(id);
            info = struct('ok', ok ~= 0, 'isDouble', type == 1, ...
                'available', avail ~= 0, 'readOnly', readOnly ~= 0, ...
                'min', mn, 'max', mx, 'default', def);
        end

        function delete(obj)
            % Leave the head off rather than trusting the caller, then
            % release it.  Only bother when this session actually turned
            % the HV on: commanding a power-off is itself a write to the
            % hardware, and merely opening the device should not cause
            % one.  A destructor must not throw.
            if obj.IsOpen
                if obj.DidEnable
                    try
                        obj.powerOff();
                    catch
                    end
                end
                try
                    Thorlabs.Pmt.TeardownDevice();
                catch
                end
                obj.IsOpen = false;
            end
        end
    end

    methods (Static, Access = private)
        function path = writeSettingsFile(folder, serial)
            % The SDK reads this from the working directory and matches
            % the head by serial.  Slot 1 holds the selected head so the
            % parameter IDs are fixed regardless of which head it is.
            path = fullfile(folder, 'ThorPMT2100Settings.xml');
            lines = {'<?xml version="1.0" encoding="UTF-8"?>', ...
                     '<ThorPMT2100Settings>', ...
                     sprintf('  <PMT1 serialNumber="%s" />', serial)};
            for k = 2:6
                lines{end+1} = sprintf('  <PMT%d serialNumber="NA" />', k); %#ok<AGROW>
            end
            lines{end+1} = '</ThorPMT2100Settings>';
            fid = fopen(path, 'w');
            if fid == -1
                error('ThorlabsPMT:settingsUnwritable', ...
                    'Cannot write the SDK settings file at %s.', path);
            end
            closeIt = onCleanup(@() fclose(fid));
            fprintf(fid, '%s\n', lines{:});
        end
    end

    methods (Access = private)
        function stage(obj, id, value)
            obj.assertOpen();
            if Thorlabs.Pmt.SetParam(id, double(value)) == 0
                error('ThorlabsPMT:setParam', ...
                    'SetParam(%d, %g) failed.', id, value);
            end
        end

        function v = read(obj, id)
            obj.assertOpen();
            [ok, v] = Thorlabs.Pmt.GetParam(id);
            if ok == 0
                error('ThorlabsPMT:getParam', 'GetParam(%d) failed.', id);
            end
        end

        function apply(obj)
            % Push everything staged so far to the hardware.  Nothing a
            % caller does takes effect until this runs.
            obj.assertOpen();
            obj.call(@Thorlabs.Pmt.PreflightPosition, 'PreflightPosition');
            obj.call(@Thorlabs.Pmt.SetupPosition,     'SetupPosition');
            obj.call(@Thorlabs.Pmt.StartPosition,     'StartPosition');

            t0 = tic;
            while true
                [ok, status] = Thorlabs.Pmt.StatusPosition();
                if ok == 0
                    error('ThorlabsPMT:status', 'StatusPosition failed.');
                end
                if status ~= obj.STATUS_BUSY
                    break;
                end
                if toc(t0) > 10
                    error('ThorlabsPMT:timeout', ...
                        'PMT did not finish applying settings within 10 s.');
                end
                pause(0.01);
            end
            obj.call(@Thorlabs.Pmt.PostflightPosition, 'PostflightPosition');
        end

        function call(~, fcn, name)
            if fcn() == 0
                error('ThorlabsPMT:sdkCall', '%s failed.', name);
            end
        end

        function assertOpen(obj)
            if ~obj.IsOpen
                error('ThorlabsPMT:closed', 'The PMT device is not open.');
            end
        end
    end
end
