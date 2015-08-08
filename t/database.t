use Mojo::Base -strict;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Test::More;
use Mojo::SQLite;
use Mojo::IOLoop;
use DBI ':sql_types';
use Mojo::Util 'encode';

# Connected
my $sql = Mojo::SQLite->new;
ok $sql->db->ping, 'connected';

# Blocking select
is_deeply $sql->db->query('select 1 as one, 2 as two, 3 as three')->hash,
  {one => 1, two => 2, three => 3}, 'right structure';

# Non-blocking select
my ($fail, $result);
my $db = $sql->db;
$db->query(
  'select 1 as one, 2 as two, 3 as three' => sub {
    my ($db, $err, $results) = @_;
    $fail   = $err;
    $result = $results->hash;
    Mojo::IOLoop->stop;
  }
);
Mojo::IOLoop->start;
ok !$fail, 'no error';
is_deeply $result, {one => 1, two => 2, three => 3}, 'right structure';

# Concurrent non-blocking selects
($fail, $result) = ();
Mojo::IOLoop->delay(
  sub {
    my $delay = shift;
    $sql->db->query('select 1 as one' => $delay->begin);
    $sql->db->query('select 2 as two' => $delay->begin);
    $sql->db->query('select 2 as two' => $delay->begin);
  },
  sub {
    my ($delay, $err_one, $one, $err_two, $two, $err_again, $again) = @_;
    $fail = $err_one || $err_two || $err_again;
    $result
      = [$one->hashes->first, $two->hashes->first, $again->hashes->first];
  }
)->wait;
ok !$fail, 'no error';
is_deeply $result, [{one => 1}, {two => 2}, {two => 2}], 'right structure';

# Sequential non-blocking selects
($fail, $result) = (undef, []);
$db = $sql->db;
Mojo::IOLoop->delay(
  sub {
    my $delay = shift;
    $db->query('select 1 as one' => $delay->begin);
  },
  sub {
    my ($delay, $err, $one) = @_;
    $fail = $err;
    push @$result, $one->hashes->first;
    $db->query('select 1 as one' => $delay->begin);
  },
  sub {
    my ($delay, $err, $again) = @_;
    $fail ||= $err;
    push @$result, $again->hashes->first;
    $db->query('select 2 as two' => $delay->begin);
  },
  sub {
    my ($delay, $err, $two) = @_;
    $fail ||= $err;
    push @$result, $two->hashes->first;
  }
)->wait;
ok !$fail, 'no error';
is_deeply $result, [{one => 1}, {one => 1}, {two => 2}], 'right structure';

# Connection cache
is $sql->max_connections, 5, 'right default';
my @dbhs = map { $_->dbh } $sql->db, $sql->db, $sql->db, $sql->db, $sql->db;
is_deeply \@dbhs,
  [map { $_->dbh } $sql->db, $sql->db, $sql->db, $sql->db, $sql->db],
  'same database handles';
@dbhs = ();
my $dbh = $sql->max_connections(1)->db->dbh;
is $sql->db->dbh, $dbh, 'same database handle';
isnt $sql->db->dbh, $sql->db->dbh, 'different database handles';
is $sql->db->dbh, $dbh, 'different database handles';
$dbh = $sql->db->dbh;
is $sql->db->dbh, $dbh, 'same database handle';
$sql->db->disconnect;
isnt $sql->db->dbh, $dbh, 'different database handles';

# Statement cache
$db = $sql->db;
my $sth = $db->query('select 3 as three')->sth;
is $db->query('select 3 as three')->sth,  $sth, 'same statement handle';
isnt $db->query('select 4 as four')->sth, $sth, 'different statement handles';
is $db->query('select 3 as three')->sth,  $sth, 'same statement handle';
undef $db;
$db = $sql->db;
my $results = $db->query('select 3 as three');
is $results->sth, $sth, 'same statement handle';
isnt $db->query('select 3 as three')->sth, $sth, 'different statement handles';
$sth = $db->query('select 3 as three')->sth;
is $db->query('select 3 as three')->sth,  $sth, 'same statement handle';
isnt $db->query('select 5 as five')->sth, $sth, 'different statement handles';
isnt $db->query('select 6 as six')->sth,  $sth, 'different statement handles';
is $db->query('select 3 as three')->sth,  $sth, 'same statement handle';

# Bind types
$db = $sql->db;
is_deeply $db->query('select ? as foo', {type => SQL_VARCHAR, value => 'bar'})
  ->hash, {foo => 'bar'}, 'right structure';
is_deeply $db->query('select ? as foo', {type => SQL_INTEGER, value => 5})
  ->hash, {foo => 5}, 'right structure';
is_deeply $db->query('select ? as foo', {type => SQL_REAL, value => 2.5})
  ->hash, {foo => 2.5}, 'right structure';
is_deeply $db->query('select ? as foo', {type => SQL_VARCHAR, value => '☃♥'})
  ->hash, {foo => '☃♥'}, 'right structure';
is_deeply $db->query('select ? as foo', {type => SQL_BLOB, value => encode 'UTF-8', '☃♥'})
  ->hash, {foo => encode 'UTF-8', '☃♥'}, 'right structure';

# Fork-safety
$dbh = $sql->db->dbh;
my ($connections, $current) = @_;
$sql->on(
  connection => sub {
    my ($sql, $dbh) = @_;
    $connections++;
    $current = $dbh;
  }
);
is $sql->db->dbh, $dbh, 'same database handle';
ok !$connections, 'no new connections';
{
  local $$ = -23;
  isnt $sql->db->dbh, $dbh,     'different database handles';
  is $sql->db->dbh,   $current, 'same database handle';
  is $connections, 1, 'one new connection';
};
$sql->unsubscribe('connection');

# Blocking error
eval { $sql->db->query('does_not_exist') };
like $@, qr/does_not_exist/, 'right error';

# Non-blocking error
($fail, $result) = ();
$db = $sql->db;
$db->query(
  'does_not_exist' => sub {
    my ($db, $err, $results) = @_;
    ($fail, $result) = ($err, $results);
    Mojo::IOLoop->stop;
  }
);
Mojo::IOLoop->start;
like $fail, qr/does_not_exist/, 'right error';
is $db->dbh->errstr, $fail, 'same error';

done_testing();
