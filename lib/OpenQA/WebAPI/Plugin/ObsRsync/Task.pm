# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Plugin::ObsRsync::Task;
use Mojo::Base 'Mojolicious::Plugin';
use Mojo::File;
use IPC::Run;
use Feature::Compat::Try;

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(obs_rsync_run => \&run);
    $app->minion->add_task(obs_rsync_update_dirty_status => \&update_dirty_status);
    $app->minion->add_task(obs_rsync_update_builds_text => \&update_obs_builds_text);
}

sub _retry_or_finish {
    my ($job, $helper, $project, $retry_interval, $retry_max_count) = @_;
    $retry_interval ||= $helper->retry_interval;
    $retry_max_count ||= $helper->retry_max_count;

    return $job->retry({delay => $retry_interval})
      if !$retry_max_count || $job->retries < $retry_max_count;

    $helper->unlock($project) if $project;
    return $job->finish(
        {code => 2, message => "Exceeded retry count $retry_max_count. Consider job will be re-triggered later"});
}

# runs script/rsync.sh from the OBS rsync home directory for a specific project
# note: The "project" is the first argument to script/rsync.sh and has a corresponding project on OBS and a corresponding
#       subdirectory in the OBS rsync home directory. This subdirectory contains many generated scripts/commands which will be
#       invoked by script/rsync.sh in a certain sequence. This Minion task merely does the top-level invocation and implements
#       a retry but is otherwise not concerned with any details (such as invoking rsync or creating openQA jobs).
#       Jobs of this task are enqueued by the "/obs_rsync/#project/runs" route (POST request) which can be triggered via the
#       "Sync now" button on the web UI (e.g. on a page like "/admin/obs_rsync/openSUSE:Factory:Staging:C").
sub run {
    my ($job, $args) = @_;

    my $app = $job->app;
    my $project = $args->{project};
    my $helper = $app->obs_rsync;
    my $home = $helper->home;
    my $queue_limit = $helper->queue_limit;

    my $retry_interval_on_exception = 120;
    my $retry_max_count_on_exception = 200;

    if ($job->info && !$job->info->{notes}{project_lock}) {
        return _retry_or_finish($job, $helper) unless $helper->lock($project);
        $job->note(project_lock => 1);
    }
    my $dirty = 0;
    try { $dirty = $helper->is_status_dirty($project, 1) }
    catch ($e) {
        _retry_or_finish($job, $helper, $project, $retry_interval_on_exception, $retry_max_count_on_exception)
    }
    return _retry_or_finish($job, $helper, $project) if $dirty;

    return _retry_or_finish($job, $helper, $project)
      unless my $concurrency_guard = $helper->concurrency_guard();

    $helper->log_job_id($project, $job->id);
    my @cmd = (Mojo::File->new($home, 'script', 'rsync.sh')->to_string, $project);
    my ($stdin, $stdout, $error);
    my $exit_code = -1;
    my $error_from_exception;
    try { IPC::Run::run(\@cmd, \$stdin, \$stdout, \$error); $exit_code = $?; }
    catch ($e) { $error_from_exception = $e }

    $helper->unlock($project);
    return $job->finish(0) if (!$exit_code);

    $error ||= $error_from_exception;
    $error ||= 'No message';
    $error =~ s/\s+$//;
    $app->log->error('ObsRsync#_run failed (' . $exit_code . '): ' . $error);
    $helper->log_failure($project, $job->id);
    return $job->fail({code => $exit_code, message => $error});
}

sub update_dirty_status {
    my ($job, $args) = @_;

    my $app = $job->app;
    my $project = $args->{project};
    my $helper = $app->obs_rsync;
    eval { $helper->is_status_dirty($project, 1); 1 };
    return $job->finish(0);
}

sub update_obs_builds_text {
    my ($job, $args) = @_;

    my $app = $job->app;
    my $alias = $args->{alias};
    my $helper = $app->obs_rsync;

    my ($project, undef) = $helper->split_alias($alias);
    # this lock indicates that rsync.sh have started - it is dangerous to call read_files.sh
    my $project_lock = Mojo::File->new($helper->home, $project, 'rsync.lock');
    return $job->finish("File exists $project_lock") if -f $project_lock;

    # this lock indicates that Gru job for project is active - it is dangerous to call read_files.sh
    my $guard = $helper->guard($project);
    return $job->finish('Gru lock exists') unless $guard;

    my $sub = sub {
        my (undef, $batch) = @_;
        my $read_files = Mojo::File->new($helper->home, $project, $batch, 'read_files.sh');
        return $job->finish("Cannot find $read_files") unless -f $read_files;

        my @cmd = ('bash', $read_files);
        my ($stdin, $stdout, $error);
        my $exit_code = -1;
        try {
            IPC::Run::run(\@cmd, \$stdin, \$stdout, \$error);
            $exit_code = $?;
            return ($exit_code, $error);
        }
        catch ($e) { return ($exit_code, $error // $e); }
    };

    my ($exit_code, $error) = $helper->for_every_batch($alias, $sub);

    return $job->fail({code => $exit_code, message => $error}) if $exit_code;
    return $job->finish('Success');
}

1;
