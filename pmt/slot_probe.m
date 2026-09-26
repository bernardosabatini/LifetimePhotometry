function slot_probe()
log = fullfile(pwd,'slot.log'); if isfile(log), delete(log); end
    function say(f_,varargin), fh=fopen(log,'a'); fprintf(fh,[f_ '\n'],varargin{:}); fclose(fh); end
serial = '00AG8701';
d = tempname; mkdir(d);
xml = sprintf(['<?xml version="1.0" encoding="UTF-8"?>\n' ...
  '<ThorPMT2100Settings>\n  <PMT1 serialNumber="%s" />\n' ...
  '  <PMT2 serialNumber="NA" />\n  <PMT3 serialNumber="NA" />\n' ...
  '  <PMT4 serialNumber="NA" />\n  <PMT5 serialNumber="NA" />\n' ...
  '  <PMT6 serialNumber="NA" />\n</ThorPMT2100Settings>\n'], serial);
fid=fopen(fullfile(d,'ThorPMT2100Settings.xml'),'w'); fprintf(fid,'%s',xml); fclose(fid);

NET.addAssembly(fullfile(pwd,'ThorPmtShim.dll'));
Thorlabs.Pmt.SetSdkDirectory('C:\Program Files\Thorlabs\PMT2100 4.0\bin\x64');
old = cd(d);
t=tic; [ok,n] = Thorlabs.Pmt.FindDevices();
say('own XML, serial in PMT1 -> FindDevices ok=%d n=%d (%.1f s)', ok, n, toc(t));
if ok~=0 && n>0
    say('SelectDevice -> %d', Thorlabs.Pmt.SelectDevice(0));
    for slot = 1:2
        gid = [700 702]; eid = [701 703];
        [r1,~,a1,ro1,mn1,mx1,~] = Thorlabs.Pmt.GetParamInfo(eid(slot));
        [r2,~,a2,~,~,mx2,~]     = Thorlabs.Pmt.GetParamInfo(gid(slot));
        say('  slot%d ENABLE(%d): infoOk=%d avail=%d ro=%d range %g..%g | GAIN(%d): infoOk=%d avail=%d max=%g', ...
            slot, eid(slot), r1, a1, ro1, mn1, mx1, gid(slot), r2, a2, mx2);
    end
    Thorlabs.Pmt.TeardownDevice();
end
cd(old);
say('DONE');
end
