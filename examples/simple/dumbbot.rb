require 'rubygems'
require 'net/yail'
require 'getopt/long'

# User specifies channel and nick
opt = Getopt::Long.getopts(
  ['--network',  Getopt::REQUIRED],
  ['--nick', Getopt::REQUIRED],
  ['--loud', Getopt::BOOLEAN]
)

irc = Net::YAIL.new(
  :address    => opt['network'],
  :username   => 'Frakking Bot',
  :realname   => 'John Botfrakker',
  :nicknames  => [opt['nick']],
)

irc.log.level = Logger::DEBUG if opt['loud']

# Register handlers
irc.heard_welcome { |e| irc.join('#bots') }
irc.on_invite     { |e| irc.join(e.channel) }

# Start the bot and enjoy the endless loop
irc.start_listening!
