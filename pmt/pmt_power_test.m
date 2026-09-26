function pmt_power_test(gains)
%PMT_POWER_TEST  Power the PMT on and off, watching the NI analog inputs.
%
%   pmt_power_test()            % default: off -> 10% -> off
%   pmt_power_test([10 30 50])  % step through several gains
%
%   Reads all five FLIM inputs with the head off, again at each gain, and
%   once more after powering down, so the effect of the HV is visible as a
%   delta against a baseline taken moments earlier.
%
%   Progress goes to pmt_test.log as it happens rather than to stdout,
%   because a hung SDK call leaves piped output invisible and there is no
%   way to tell how far it got.
%
%   The head is powered off through onCleanup, so an error or Ctrl-C
%   still leaves it off.
%
%   NOTE ON THE TRIP FLAG: this unit reports the same SAFETY value in
%   every state - off, on, and after a large signal excursion - so it is
%   logged for the record but never used to decide anything.

    if nargin < 1 || isempty(gains)
        gains = 10;
    end

    addpath('C:/ClaudeCode/FLIMIR_DataAcq');
    log = fullfile(fileparts(mfilename('fullpath')), 'pmt_test.log');
    if isfile(log)
        delete(log);
    end

    try
        daqreset;
    catch
    end
    q = daq('ni');
    for c = {'ai0', 'ai1', 'ai2', 'ai3', 'ai4'}
        addinput(q, 'Dev1', c{1}, 'Voltage');
    end
    q.Rate = 1000;
    say(log, 'NI ready');

    p = ThorlabsPMT(2);
    guard = onCleanup(@() shutdown(p, log));
    say(log, 'PMT opened, slot %d', p.Slot);

    say(log, '%-22s %9s %9s %9s %9s %9s  %s', ...
        'state', 'ai0', 'ai1', 'ai2', 'ai3', 'ai4', 'trip');
    base = readAI(q);
    say(log, '%-22s %9.4f %9.4f %9.4f %9.4f %9.4f  %s', ...
        'PMT off (baseline)', base, tripText(p));

    for g = gains(:)'
        p.powerOn(g);
        pause(0.5);                    % let the HV and the output filter settle
        v = readAI(q);
        say(log, '%-22s %9.4f %9.4f %9.4f %9.4f %9.4f  %s', ...
            sprintf('PMT on, gain %d%%', g), v, tripText(p));
        say(log, '%-22s %9.4f %9.4f %9.4f %9.4f %9.4f', ...
            '   delta vs baseline', v - base);
    end

    p.powerOff();
    pause(0.5);
    off = readAI(q);
    say(log, '%-22s %9.4f %9.4f %9.4f %9.4f %9.4f  %s', ...
        'PMT off again', off, tripText(p));
    say(log, '%-22s %9.4f %9.4f %9.4f %9.4f %9.4f', ...
        '   residual vs baseline', off - base);

    clear q
    say(log, 'DONE');
end

% =========================================================================

function v = readAI(q)
    v = mean(read(q, 500, 'OutputFormat', 'Matrix'), 1);   % 0.5 s mean
end

function s = tripText(p)
    [tf, known] = p.isTripped();
    if ~known
        s = 'unreadable';
    elseif tf
        s = '1';
    else
        s = '0';
    end
end

function say(log, fmt, varargin)
    line = sprintf(fmt, varargin{:});
    fh = fopen(log, 'a');
    fprintf(fh, '%s\n', line);
    fclose(fh);
end

function shutdown(p, log)
    try
        p.powerOff();
        say(log, 'cleanup: powered off');
    catch ME
        say(log, 'cleanup powerOff failed: %s', ME.message);
    end
    try
        delete(p);
        say(log, 'cleanup: released');
    catch
    end
end
