package PVE::API2::ProxMorph;

use strict;
use warnings;

use JSON;

use PVE::Cluster qw(cfs_lock_file cfs_read_file cfs_register_file cfs_write_file);
use PVE::RPCEnvironment;
use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

my $preferences_file = 'priv/proxmorph-user-preferences.json';
my @preference_keys = qw(
    useIconNavigation
    groupByNode
    showPools
    showVirtualMachines
    showContainers
    showTemplates
    showStorage
    showNetwork
    showStoppedGuests
);

my $defaults = {
    useIconNavigation => 0,
    groupByNode => 1,
    showPools => 1,
    showVirtualMachines => 1,
    showContainers => 1,
    showTemplates => 1,
    showStorage => 0,
    showNetwork => 0,
    showStoppedGuests => 1,
};

my $parse_preferences = sub {
    my ($filename, $raw) = @_;

    return { schema => 1, users => {} } if !defined($raw) || $raw eq '';

    my $config = eval { decode_json($raw) };
    die "unable to parse ProxMorph user preferences: $@" if $@;
    die "invalid ProxMorph user preferences in '$filename'\n"
        if ref($config) ne 'HASH' || ref($config->{users}) ne 'HASH';

    $config->{schema} = 1;
    return $config;
};

my $write_preferences = sub {
    my ($filename, $config) = @_;

    die "invalid ProxMorph user preferences for '$filename'\n"
        if ref($config) ne 'HASH' || ref($config->{users}) ne 'HASH';

    return encode_json($config) . "\n";
};

cfs_register_file($preferences_file, $parse_preferences, $write_preferences);

my $preference_schema = {
    type => 'boolean',
    optional => 1,
};

my $return_schema = {
    type => 'object',
    additionalProperties => 0,
    properties => { map { $_ => { type => 'boolean' } } @preference_keys },
};

sub current_preferences {
    my ($authuser) = @_;

    my $config = cfs_read_file($preferences_file);
    my $saved = $config->{users}->{$authuser};
    my $result = { %$defaults };

    if (ref($saved) eq 'HASH') {
        for my $key (@preference_keys) {
            $result->{$key} = $saved->{$key} ? 1 : 0 if exists($saved->{$key});
        }
    }

    return $result;
}

__PACKAGE__->register_method({
    name => 'get_preferences',
    path => 'preferences',
    method => 'GET',
    description => 'Get inventory-view preferences for the authenticated Proxmox user.',
    permissions => { user => 'all' },
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => $return_schema,
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        return current_preferences($authuser);
    },
});

__PACKAGE__->register_method({
    name => 'set_preferences',
    path => 'preferences',
    method => 'PUT',
    description => 'Save inventory-view preferences for the authenticated Proxmox user.',
    permissions => { user => 'all' },
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => { map { $_ => { %$preference_schema } } @preference_keys },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        cfs_lock_file(
            $preferences_file,
            undef,
            sub {
                my $config = cfs_read_file($preferences_file);
                my $saved = $config->{users}->{$authuser};
                $saved = { %$defaults } if ref($saved) ne 'HASH';

                for my $key (@preference_keys) {
                    $saved->{$key} = $param->{$key} ? 1 : 0 if exists($param->{$key});
                }

                $config->{schema} = 1;
                $config->{users}->{$authuser} = $saved;
                cfs_write_file($preferences_file, $config, 1);
            },
        );
        die $@ if $@;

        return undef;
    },
});

1;
