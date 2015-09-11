use Mojo::Base -strict;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Test::More;

use File::Spec::Functions 'catfile';
use File::Temp;
use Mojo::IOLoop;
use Mojo::SQLite;

my $tempdir = File::Temp->newdir;
my $tempfile = catfile($tempdir, 'test.db');

# Notifications with event loop
my $sql = Mojo::SQLite->new->from_filename($tempfile);
my ($db, @all, @test);
$sql->pubsub->poll_interval(0.1)->on(reconnect => sub { $db = pop });
$sql->pubsub->listen(
  pstest => sub {
    my ($pubsub, $payload) = @_;
    push @test, $payload;
    Mojo::IOLoop->next_tick(sub { $pubsub->sqlite->db->notify(pstest => 'stop') });
    Mojo::IOLoop->stop if $payload eq 'stop';
  }
);
$db->on(notification => sub { push @all, [@_[1, 2]] });
$sql->db->notify(pstest => 'test');
Mojo::IOLoop->start;
is_deeply \@test, ['test', 'stop'], 'right messages';
is_deeply \@all, [['pstest', 'test'], ['pstest', 'stop']],
  'right notifications';

# Unsubscribe
$sql = Mojo::SQLite->new->from_filename($tempfile);
$db = undef;
$sql->pubsub->poll_interval(0.1)->on(reconnect => sub { $db = pop });
@all = @test = ();
my $first  = $sql->pubsub->listen(pstest => sub { push @test, pop });
my $second = $sql->pubsub->listen(pstest => sub { push @test, pop });
$db->on(notification => sub { push @all, [@_[1, 2]] });
$sql->pubsub->notify('pstest')->notify(pstest => 'first');
is_deeply \@test, ['', '', 'first', 'first'], 'right messages';
is_deeply \@all, [['pstest', ''], ['pstest', 'first']], 'right notifications';
$sql->pubsub->unlisten(pstest => $first)->notify(pstest => 'second');
is_deeply \@test, ['', '', 'first', 'first', 'second'], 'right messages';
is_deeply \@all, [['pstest', ''], ['pstest', 'first'], ['pstest', 'second']],
  'right notifications';
$sql->pubsub->unlisten(pstest => $second)->notify(pstest => 'third');
is_deeply \@test, ['', '', 'first', 'first', 'second'], 'right messages';
is_deeply \@all, [['pstest', ''], ['pstest', 'first'], ['pstest', 'second']],
  'right notifications';

# Reconnect while listening
$sql = Mojo::SQLite->new->from_filename($tempfile);
my @dbhs = @test = ();
$sql->pubsub->poll_interval(0.1)->on(reconnect => sub { push @dbhs, $db->dbh });
$sql->pubsub->listen(pstest => sub { push @test, pop });
ok $dbhs[0], 'database handle';
is_deeply \@test, [], 'no messages';
{
  $sql->pubsub->on(
    reconnect => sub { shift->notify(pstest => 'works'); Mojo::IOLoop->stop });
  $dbhs[0]->disconnect;
  Mojo::IOLoop->start;
  ok $dbhs[1], 'database handle';
  isnt $dbhs[0], $dbhs[1], 'different database handles';
  is_deeply \@test, ['works'], 'right messages';
};

# Reconnect while not listening
$sql = Mojo::SQLite->new->from_filename($tempfile);
@dbhs = @test = ();
$sql->pubsub->poll_interval(0.1)->on(reconnect => sub { push @dbhs, $db->dbh });
$sql->pubsub->notify(pstest => 'fail');
ok $dbhs[0], 'database handle';
is_deeply \@test, [], 'no messages';
{
  $sql->pubsub->on(reconnect => sub { Mojo::IOLoop->stop });
  $dbhs[0]->disconnect;
  Mojo::IOLoop->start;
  ok $dbhs[1], 'database handle';
  isnt $dbhs[0], $dbhs[1], 'different database handles';
  $sql->pubsub->listen(pstest => sub { push @test, pop });
  $sql->pubsub->notify(pstest => 'works too');
  is_deeply \@test, ['works too'], 'right messages';
};

# Fork-safety
$sql = Mojo::SQLite->new->from_filename($tempfile);
@dbhs = @test = ();
$sql->pubsub->poll_interval(0.1)->on(reconnect => sub { push @dbhs, pop->dbh });
$sql->pubsub->listen(pstest => sub { push @test, pop });
ok $dbhs[0], 'database handle';
ok $dbhs[0]->ping, 'connected';
$sql->pubsub->notify(pstest => 'first');
is_deeply \@test, ['first'], 'right messages';
{
  local $$ = -23;
  $sql->pubsub->notify(pstest => 'second');
  ok $dbhs[1], 'database handle';
  ok $dbhs[1]->ping, 'connected';
  isnt $dbhs[0], $dbhs[1], 'different database handles';
  ok !$dbhs[0]->ping, 'not connected';
  is_deeply \@test, ['first'], 'right messages';
  $sql->pubsub->listen(pstest => sub { push @test, pop });
  $sql->pubsub->notify(pstest => 'third');
  ok $dbhs[1]->ping, 'connected';
  ok !$dbhs[2], 'no database handle';
  is_deeply \@test, ['first', 'third'], 'right messages';
};

done_testing();
