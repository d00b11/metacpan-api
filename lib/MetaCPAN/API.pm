package MetaCPAN::API;

=head1 DESCRIPTION

This is not a web app.  It's purely here to manage the API's release indexing
queue.

    # On vagrant VM
    ./bin/run morbo bin/queue.pl

    # Display information on jobs in queue
    ./bin/run bin/queue.pl minion job

To run the minion admin web interface, run the following on one of the servers:

    # Run the daemon on a local port (tunnel to display on your browser)
    ./bin/run bin/queue.pl daemon

=cut

use Mojo::Base 'Mojolicious';

use Config::ZOMG ();
use File::Temp   ();
use List::Util qw( any );
use MetaCPAN::Model::Search  ();
use MetaCPAN::Model::User    ();
use MetaCPAN::Script::Runner ();
use Search::Elasticsearch    ();
use Try::Tiny qw( catch try );

has es => sub {
    return Search::Elasticsearch->new(
        client => '2_0::Direct',
        nodes  => [':9200'],       #TODO config
    );
};

has model_search => sub {
    my $self = shift;
    return MetaCPAN::Model::Search->new(
        es    => $self->es,
        index => 'cpan',
    );
};

has model_user => sub {
    my $self = shift;
    return MetaCPAN::Model::User->new( es => $self->es, );
};

sub startup {
    my $self = shift;

    unless ( $self->config->{config_override} ) {
        $self->config(
            Config::ZOMG->new(
                name => 'metacpan_server',
                path => $self->home->to_string,
            )->load
        );
    }

    # TODO secret from config
    $self->secrets( [ $ENV{MOJO_SECRET} ] );

    $self->static->paths( [ $self->home->child('root') ] );

    if ( $ENV{HARNESS_ACTIVE} ) {
        my $file = File::Temp->new( UNLINK => 1, SUFFIX => '.db' );
        $self->plugin( Minion => { SQLite => 'sqlite:' . $file } );
    }
    else {
        $self->plugin( Minion => { Pg => $self->config->{minion_dsn} } );
    }

    $self->minion->add_task(
        index_release => $self->_gen_index_task_sub('release') );

    $self->minion->add_task(
        index_latest => $self->_gen_index_task_sub('latest') );

    $self->minion->add_task(
        index_favorite => $self->_gen_index_task_sub('favorite') );

    $self->_maybe_set_up_routes;
}

sub _gen_index_task_sub {
    my ( $self, $type ) = @_;

    return sub {
        my ( $job, @args ) = @_;

        my @warnings;
        local $SIG{__WARN__} = sub {
            push @warnings, $_[0];
            warn $_[0];
        };

        # @args could be ( '--latest', '/path/to/release' );
        unshift @args, $type;

        # Runner expects to have been called via CLI
        local @ARGV = @args;
        try {
            MetaCPAN::Script::Runner->run(@args);
            $job->finish( @warnings ? { warnings => \@warnings } : () );
        }
        catch {
            warn $_;
            $job->fail(
                {
                    message => $_,
                    @warnings ? ( warnings => \@warnings ) : (),
                }
            );
        };
        }
}

sub _maybe_set_up_routes {
    my $self = shift;
    return unless $ENV{MOJO_SECRET} && $ENV{GITHUB_KEY};

    my $r = $self->routes;

    $self->plugin(
        'Web::Auth',
        module      => 'Github',
        key         => $ENV{GITHUB_KEY},
        secret      => $ENV{GITHUB_SECRET},
        on_finished => sub {
            my ( $c, $access_token, $account_info ) = @_;
            my $login = $account_info->{login};
            if ( $self->_is_admin($login) ) {
                $c->session( username => $login );
                $c->redirect_to('/admin');
                return;
            }
            return $c->render(
                text => "$login is not authorized to access this application",
                status => 403
            );
        },
    );

    my $admin = $r->under(
        '/admin' => sub {
            my $c = shift;
            return 1 if $self->_is_admin( $c->session('username') );
            $c->redirect_to('/auth/github/authenticate');
            return 0;
        }
    );

    $admin->get('home')->to('admin#home')->name('admin-home');
    $admin->post('enqueue')->to('queue#enqueue')->name('enqueue');
    $admin->post('search-identities')->to('admin#search_identities')
        ->name('search-identities');
    $admin->get('index-release')->to('queue#index_release')
        ->name('index-release');
    $admin->get('identity-search-form')->to('admin#identity_search_form')
        ->name('identity_search_form');

    $self->plugin( 'Minion::Admin' => { route => $admin->any('/minion') } );
    $self->plugin(
        'OpenAPI' => { url => $self->home->rel_file('root/static/v1.yml') } );
    $self->plugin(
        MountPSGI => { '/' => $self->home->child('app.psgi')->to_string } );

}

sub _is_admin {
    my $self = shift;
    my $username
        = shift || ( $ENV{HARNESS_ACTIVE} ? $ENV{FORCE_ADMIN_AUTH} : () );
    return 0 unless $username;

    my @admins = (
        'haarg', 'jberger', 'mickeyn', 'oalders',
        'ranguard', 'reyjrar', 'ssoriche',
        $ENV{HARNESS_ACTIVE} ? 'tester' : (),
    );

    return any { $username eq $_ } @admins;
}

1;
