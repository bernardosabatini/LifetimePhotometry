function backends = flimir_daq_backends()
%FLIMIR_DAQ_BACKENDS  Discover the available DAQ backends.
%
%   backends = flimir_daq_backends()
%
%   Returns a struct array with fields 'class' and 'name', one entry per
%   concrete FlimirDaqDevice subclass found next to this file.  Dropping a
%   new backend class into the folder is all that is needed for it to
%   appear in the application's Backend menu.
%
%   See also FLIMIRDAQDEVICE.

    backends = struct('class', {}, 'name', {});

    here = fileparts(mfilename('fullpath'));
    files = dir(fullfile(here, 'FlimirDaq*.m'));

    for i = 1:numel(files)
        [~, className] = fileparts(files(i).name);
        if strcmp(className, 'FlimirDaqDevice')
            continue;   % the abstract base itself
        end
        try
            % Do not name this 'meta': that would shadow the meta package
            % and every lookup below would silently fail into the catch.
            mc = meta.class.fromName(className);
            if isempty(mc) || mc.Abstract
                continue;
            end
            if ~any(strcmp({mc.SuperclassList.Name}, 'FlimirDaqDevice'))
                continue;
            end
            backends(end+1).class = className; %#ok<AGROW>
            backends(end).name = feval([className '.backendName']);
        catch
            % A class that fails to load should not stop the others
        end
    end

    % Stable, predictable order in the UI
    if ~isempty(backends)
        [~, order] = sort({backends.name});
        backends = backends(order);
    end
end
