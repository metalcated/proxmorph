package PVE::API2::ProxMorph;

use strict;
use warnings;

use JSON;

use PVE::Cluster qw(cfs_lock_file cfs_read_file cfs_register_file cfs_write_file);
use PVE::RPCEnvironment;
use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

my $preferences_file = 'priv/proxmorph-user-preferences.json';
my @boolean_preference_keys = qw(
    useIconNavigation
    groupByNode
    showPools
    showVirtualMachines
    showContainers
    showTemplates
    showStorage
    showNetwork
    showStoppedGuests
    noVncContextMenu
    noVncClipboardShortcuts
);
my @choice_preference_keys = qw(uiFont uiTextSize);
my %choice_preference_values = (
    uiFont => [qw(default modern)],
    uiTextSize => [qw(default comfortable large)],
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
    noVncContextMenu => 1,
    noVncClipboardShortcuts => 0,
    uiFont => 'default',
    uiTextSize => 'default',
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

my $return_properties = {};
my $parameter_properties = {};

for my $key (@boolean_preference_keys) {
    $return_properties->{$key} = { type => 'boolean' };
    $parameter_properties->{$key} = { type => 'boolean', optional => 1 };
}

for my $key (@choice_preference_keys) {
    $return_properties->{$key} = {
        type => 'string',
        enum => $choice_preference_values{$key},
    };
    $parameter_properties->{$key} = {
        type => 'string',
        enum => $choice_preference_values{$key},
        optional => 1,
    };
}

my $return_schema = {
    type => 'object',
    additionalProperties => 0,
    properties => $return_properties,
};

sub valid_choice {
    my ($key, $value) = @_;

    return 0 if !defined($value);
    return scalar grep { $_ eq $value } @{$choice_preference_values{$key}};
}

sub current_preferences {
    my ($authuser) = @_;

    my $config = cfs_read_file($preferences_file);
    my $saved = $config->{users}->{$authuser};
    my $result = { %$defaults };

    if (ref($saved) eq 'HASH') {
        for my $key (@boolean_preference_keys) {
            $result->{$key} = $saved->{$key} ? 1 : 0 if exists($saved->{$key});
        }
        for my $key (@choice_preference_keys) {
            $result->{$key} = $saved->{$key}
                if exists($saved->{$key}) && valid_choice($key, $saved->{$key});
        }
    }

    return $result;
}

__PACKAGE__->register_method({
    name => 'get_preferences',
    path => 'preferences',
    method => 'GET',
    description => 'Get inventory, appearance, and console preferences for the authenticated Proxmox user.',
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
    description => 'Save inventory, appearance, and console preferences for the authenticated Proxmox user.',
    permissions => { user => 'all' },
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => $parameter_properties,
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

                for my $key (@boolean_preference_keys) {
                    $saved->{$key} = $param->{$key} ? 1 : 0 if exists($param->{$key});
                }
                for my $key (@choice_preference_keys) {
                    $saved->{$key} = $param->{$key}
                        if exists($param->{$key}) && valid_choice($key, $param->{$key});
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
