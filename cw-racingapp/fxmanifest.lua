-- Resource Metadata
fx_version 'cerulean'
games { 'gta5' }

author 'Coffeelot & Wuggie'
description 'CW Racing App'
version '5.0.6'

ui_page {
    "web/dist/index.html"
}

shared_scripts {
    'locales/en.lua',
    'locales/pt.lua',
    'shared/config.lua',
    'shared/elo.lua',
    'shared/head2head.lua',
}

client_scripts {
    'bridge/client/vrp.lua',
    'client/classes.lua',
    'client/globals.lua',
    'client/functions.lua',
    'client/main.lua',
    'client/gui.lua',
    'client/head2head.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/debug.lua',
    'server/database.lua',
    'server/databaseTimes.lua',
    'server/functions.lua',
    'server/main.lua',
    'server/crypto.lua',
    'server/crews.lua',
    'server/elo.lua',
    'server/bounties.lua',
    'server/head2head.lua',
    'bridge/server/vrp.lua'
}

files {
    "web/dist/index.html",
    "web/dist/assets/*.*",
    "race_notification.wav",
}

dependencies {
    'cw-performance',
    'vrp'
}

lua54 'yes'
