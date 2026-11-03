var exec = require('cordova/exec');
module.exports = {
    start:         function (opts, ok, err) { exec(ok, err, 'HotspotProxy', 'start', [opts || {}]); },
    stop:          function (ok, err) { exec(ok, err, 'HotspotProxy', 'stop', []); },
    status:        function (ok, err) { exec(ok, err, 'HotspotProxy', 'status', []); },
    batteryStatus: function (ok, err) { exec(ok, err, 'HotspotProxy', 'batteryStatus', []); },
    batteryExempt: function (ok, err) { exec(ok, err, 'HotspotProxy', 'batteryExempt', []); }
};
