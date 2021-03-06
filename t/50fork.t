use strict;
use warnings;
use Test::More;

my ($dsn, $user, $pass) = @ENV{map { "DBICTEST_PG_${_}" } qw/DSN USER PASS/};

plan skip_all => 'Set $ENV{DBICTEST_PG_DSN}, _USER and _PASS to run this test'
      . ' (note: creates and drops a table named artist!)' unless ($dsn && $user);

# README: If you set the env var to a number greater than 10,
#   we will use that many children
my $num_children = $ENV{DBICTEST_FORK_STRESS} || 1;
if($num_children !~ /^[0-9]+$/ || $num_children < 10) {
   $num_children = 10;
}

plan tests => ($num_children*2) + 6;

use lib qw(t/lib);

use_ok('DBICTest::Schema');

my $schema = DBICTest::Schema->connection($dsn, $user, $pass, { AutoCommit => 1 });

my $parent_rs;

eval {
    my $dbh = $schema->storage->dbh;

    {
        local $SIG{__WARN__} = sub {};
        eval { $dbh->do("DROP TABLE cd") };
        $dbh->do("CREATE TABLE cd (cdid serial PRIMARY KEY, artist INTEGER NOT NULL UNIQUE, title VARCHAR(100) NOT NULL UNIQUE, year VARCHAR(100) NOT NULL, genreid INTEGER, single_track INTEGER);");
    }

    $schema->resultset('CD')->create({ title => 'vacation in antarctica', artist => 123, year => 1901 });
    $schema->resultset('CD')->create({ title => 'vacation in antarctica part 2', artist => 456, year => 1901 });

    $parent_rs = $schema->resultset('CD')->search({ year => 1901 });
    $parent_rs->next;
};
ok(!$@) or diag "Creation eval failed: $@";

{
    my $pid = fork;
    if(!defined $pid) {
        die "fork failed: $!";
    }

    if (!$pid) {
        exit $schema->storage->connected ? 1 : 0;
    }

    if (waitpid($pid, 0) == $pid) {
        my $ex = $? >> 8;
        ok($ex == 0, "storage->connected() returns false in child");
        exit $ex if $ex; # skip remaining tests
    }
}

my @pids;
while(@pids < $num_children) {

    my $pid = fork;
    if(!defined $pid) {
        die "fork failed: $!";
    }
    elsif($pid) {
        push(@pids, $pid);
        next;
    }

    $pid = $$;

    my $work = sub {
      my $child_rs = $schema->resultset('CD')->search({ year => 1901 });
      my $row = $parent_rs->next;
      $schema->resultset('CD')->create({ title => "test success $pid", artist => $pid, year => scalar(@pids) })
        if($row && $row->get_column('artist') =~ /^(?:123|456)$/);
    };

    # try with and without transactions
    if ((@pids % 3) == 1) {
      my $guard = $schema->txn_scope_guard;
      $work->();
      $guard->commit;
    }
    elsif ((@pids % 3) == 2) {
      $schema->txn_do ($work);
    }
    else {
      $work->();
    }

    sleep(3);
    exit 0;
}

ok(1, "past forking");

for (@pids) {
  waitpid($_,0);
  ok (! $?, "Child $_ exitted cleanly");
};

ok(1, "past waiting");

while(@pids) {
    my $pid = pop(@pids);
    my $rs = $schema->resultset('CD')->search({ title => "test success $pid", artist => $pid, year => scalar(@pids) });
    is($rs->next->get_column('artist'), $pid, "Child $pid successful");
}

ok(1, "Made it to the end");

$schema->storage->dbh->do("DROP TABLE cd");
