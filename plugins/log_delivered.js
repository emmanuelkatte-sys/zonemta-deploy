'use strict';

// ZonePMTA local delivered logger (Safe clean edition - Telegram disabled).
const fs = require('fs');
const path = require('path');

module.exports.title = 'Local Delivered Logger (Clean)';

const dataDir = '/opt/zone-mta/plugins/data';
const counterTotalFile = path.join(dataDir, 'counter_total.txt');

let memCounterTotal = 0;

module.exports.init = function(app, done) {
    try {
        fs.mkdirSync(dataDir, { recursive: true });
        if (fs.existsSync(counterTotalFile)) {
            memCounterTotal = parseInt(fs.readFileSync(counterTotalFile, 'utf8'), 10) || 0;
        }
    } catch (e) {}

    app.addHook('sender:delivered', (delivery, info, next) => {
        try {
            if (delivery && delivery.status && delivery.status.delivered !== false) {
                memCounterTotal++;
                if (memCounterTotal % 100 === 0) {
                    fs.writeFileSync(counterTotalFile, String(memCounterTotal));
                }
            }
        } catch (e) {}
        next();
    });

    done();
};
