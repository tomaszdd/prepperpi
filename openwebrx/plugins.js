// Touch-friendly tuning controls: step up/down, scan to next/prev signal,
// and toggle the bookmark auto-scanner. All three call OpenWebRX+'s own
// existing functions (normally only reachable via keyboard shortcuts:
// Left/Right arrow = step, [ / ] = scan-by-squelch, S = bookmark scanner).
(function () {
    function addBar() {
        if ($('#touch-tune-bar').length) return;
        if (typeof tuneBySteps !== 'function' || typeof tuneBySquelch !== 'function') {
            // Scripts not loaded yet, retry shortly.
            setTimeout(addBar, 500);
            return;
        }

        var bar = $(
            '<div id="touch-tune-bar" style="' +
            'position:fixed;left:50%;transform:translateX(-50%);bottom:8px;z-index:1000;' +
            'display:flex;gap:6px;background:rgba(20,20,20,0.85);padding:6px;border-radius:10px;' +
            'box-shadow:0 2px 8px rgba(0,0,0,0.5);">' +
            '<button data-act="step-down" title="Step down">&#9664; Step</button>' +
            '<button data-act="step-up" title="Step up">Step &#9654;</button>' +
            '<button data-act="scan-down" title="Scan to previous signal">&#9198; Scan</button>' +
            '<button data-act="scan-up" title="Scan to next signal">Scan &#9197;</button>' +
            '<button data-act="scan-toggle" id="touch-scan-toggle" title="Toggle bookmark auto-scan">&#128270; Auto</button>' +
            '</div>'
        );

        bar.find('button').css({
            'background': '#f59e0b',
            'color': '#111',
            'border': 'none',
            'border-radius': '6px',
            'padding': '10px 12px',
            'font-size': '14px',
            'font-weight': 'bold',
            'touch-action': 'manipulation'
        });

        bar.on('click', 'button', function (e) {
            e.preventDefault();
            var act = $(this).data('act');
            switch (act) {
                case 'step-down': tuneBySteps(-1); break;
                case 'step-up': tuneBySteps(1); break;
                case 'scan-down': tuneBySquelch(-1); break;
                case 'scan-up': tuneBySquelch(1); break;
                case 'scan-toggle':
                    UI.toggleScanner();
                    $('#touch-scan-toggle').css('outline', scanner.isRunning() ? '2px solid #3fb950' : 'none');
                    break;
            }
        });

        $('body').append(bar);
    }

    $(document).ready(function () {
        addBar();
    });
})();
