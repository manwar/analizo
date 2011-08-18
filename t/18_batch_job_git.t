package Analizo::Batch::Job::Git::Test;
use strict;
use warnings;

use base 'Test::Class';
use Test::More;
use Test::Analizo;
use Cwd;
use File::Basename;
use Test::MockObject;
use Test::Analizo::Git;

use Analizo::Batch::Job::Git;
use Analizo::Batch::Git;

my $TESTDIR = 'evolution';


sub constructor : Tests {
  isa_ok(__create(), 'Analizo::Batch::Job::Git');
}

sub constructor_with_arguments : Tests {
  my $id = $MASTER;
  my $job = __create($TESTDIR, $id);
  is($job->directory, $TESTDIR);
  is($job->{actual_directory}, $TESTDIR);
  is($job->id, $id);
}

sub parallelism_support : Tests {
  my $job = __create($TESTDIR, $MASTER);
  $job->parallel_prepare();

  isnt($job->{actual_directory}, $TESTDIR);
  ok(-d $job->{actual_directory}, "different work directory must be created");
  ok(-d File::Spec->catfile($job->{actual_directory}, '.git'), "content must be copied");

  $job->parallel_cleanup();
  ok(! -d $job->{actual_directory}, "different work directory must be removed when parallel_cleanup is called.");

  is($job->project_name, basename($TESTDIR), 'parallelism support must not mess with project name');
}

sub prepare_and_cleanup : Tests {
  my $job = mock(__create($TESTDIR, $SOME_COMMIT));

  my @checkouts = ();
  $job->mock('git_checkout', sub { push @checkouts, $_[1]; } );
  my $oldcwd = getcwd();
  $job->prepare();
  my $newcwd = getcwd();
  $job->cleanup();

  ok($newcwd ne $oldcwd, 'prepare must change dir');
  ok(getcwd eq $oldcwd, 'cleanup must change cwd back');
  is_deeply(\@checkouts, [$SOME_COMMIT, 'master'], 'cleanup must checkout given commit and go back to previous one');
}

sub git_checkout_should_actually_checkout : Tests {
  my $job = __create($TESTDIR, $SOME_COMMIT);
  my $getHEAD = sub {
    $job->git_HEAD();
  };
  my $master1 = on_dir($TESTDIR, $getHEAD);
  $job->prepare();
  my $commit = $job->git_HEAD;
  $job->cleanup();
  my $master2 = on_dir($TESTDIR, $getHEAD);
  my $branch = on_dir($TESTDIR, sub { $job->git_current_branch() });

  is($commit, $SOME_COMMIT);
  is($master1, $master2);
  is($master2, $MASTER);
  is($branch, 'master');
}

sub points_to_batch : Tests {
  my $job = __create();
  $job->batch(42);
  is($job->batch, 42);
}

sub changed_files : Tests {
  my $repo = __create_repo($TESTDIR);

  my $master = $repo->find($MASTER);
  is_deeply($master->changed_files, {'input.cc' => 'M'});

  my $some_commit = $repo->find($SOME_COMMIT);
  is_deeply($some_commit->changed_files, {'prog.cc' => 'M'});

  my $add_output_commit = $repo->find($ADD_OUTPUT_COMMIT);
  is_deeply($add_output_commit->changed_files, { 'output.cc' => 'A', 'output.h' => 'A', 'prog.cc' => 'M' });
}

sub previous_relevant : Tests {
  my $batch = __create_repo($TESTDIR);

  my $first = $batch->find($FIRST_COMMIT);
  is($first->previous_relevant, undef);

  my $master = $batch->find($MASTER);
  isa_ok($master->previous_relevant, 'Analizo::Batch::Job::Git');
  is($master->previous_relevant->id, '0a06a6fcc2e7b4fe56d134e89d74ad028bb122ed');

  my $commit = $batch->find('0a06a6fcc2e7b4fe56d134e89d74ad028bb122ed');
  isa_ok($commit->previous_relevant, 'Analizo::Batch::Job::Git');
  is($commit->previous_relevant->id, 'eb67c27055293e835049b58d7d73ce3664d3f90e');
}

sub previous_wanted : Tests {
  my $batch = __create_repo($TESTDIR);

  my $master = $batch->find($MASTER);
  is($master->previous_wanted, $master->previous_relevant);

  my $merge = $batch->find($MERGE_COMMIT);
  is($merge->previous_wanted, undef);
}

sub metadata : Tests {
  my $repo = __create_repo($TESTDIR);
  my $master = $repo->find($MASTER);

  my $metadata = $master->metadata();
  metadata_ok($metadata, 'author_name', 'Antonio Terceiro', 'author name');
  metadata_ok($metadata, 'author_email', 'terceiro@softwarelivre.org', 'author email');
  metadata_ok($metadata, 'author_date', 1297788040, 'author date'); # UNIX timestamp for [Tue Feb 15 13:40:40 2011 -0300]
  metadata_ok($metadata, 'previous_commit_id', '0a06a6fcc2e7b4fe56d134e89d74ad028bb122ed', 'previous commit');
  metadata_ok($metadata, 'changed_files', {'input.cc' => 'M'}, 'changed files');

  my @files_entry = grep { $_->[0] eq 'files' } @$metadata;
  my $files = $files_entry[0]->[1];

  is($files->{'input.cc'},   '0e85dc55b30f5e257ce5615bfcb229d1ace13e01');
  is($files->{'input.h'},    '44edccb29f8b8ba252f15988edacfad481606c45');
  is($files->{'output.cc'},  'ed526e137858cb903730a1886db430c28d6bebcf');
  is($files->{'output.h'},   'a67e1b0986b9cab18fbbb12d0f941982c74d724d');
  is($files->{'prog.cc'},    '91745088e303c9440b6d58a5232b5d753d3c91f5');
  ok(!defined($files->{Makefile}), 'must not include non-code files in tree');

  my $first = $repo->find($FIRST_COMMIT);
  metadata_ok($first->metadata, 'previous_commit_id', undef, 'unexisting commit id');
}

sub merge_and_first_commit_detection : Tests {
  my $repo = __create_repo($TESTDIR);
  my $master = $repo->find($MASTER);
  ok(!$master->is_merge);
  ok(!$master->is_first_commit);

  my $first = $repo->find($FIRST_COMMIT);
  ok($first->is_first_commit);

  my $merge = $repo->find($MERGE_COMMIT);
  ok($merge->is_merge);
}

sub metadata_ok {
  my ($metadata,$field,$value,$testname) = @_;
  if (is(ref($metadata), 'ARRAY', $testname))  {
    my @entries = grep { $_->[0] eq $field } @$metadata;
    my $entry = $entries[0];
    if (is(ref($entry), 'ARRAY', $testname)) {
      is_deeply($entry->[1], $value, $testname);
    }
  }
}

sub __create {
  my @args = @_;
  new Analizo::Batch::Job::Git(@args);
}

sub __create_repo {
  my @args = @_;
  my $repo = new Analizo::Batch::Git(@args);
  $repo->initialize();
  return $repo;
}

unpack_sample_git_repository(
  sub {
    my $cwd = getcwd;
    chdir tmpdir();
    __PACKAGE__->runtests;
    chdir $cwd;
  }
);