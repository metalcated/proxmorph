#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
use JSON::PP ();
use Test::More;

BEGIN {
    package JSON;

    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::decode_json"} = \&JSON::PP::decode_json;
        *{"${caller}::encode_json"} = \&JSON::PP::encode_json;
    }

    $INC{'JSON.pm'} = 1;

    package PVE::Cluster;

    our $config = { schema => 1, users => {} };
    our ($registered_file, $parser, $writer);

    sub import {
        my ($class, @symbols) = @_;
        my $caller = caller;
        no strict 'refs';
        for my $symbol (@symbols) {
            *{"${caller}::${symbol}"} = \&{$symbol};
        }
    }

    sub cfs_register_file {
        ($registered_file, $parser, $writer) = @_;
    }

    sub cfs_read_file {
        return $config;
    }

    sub cfs_write_file {
        my ($filename, $new_config) = @_;
        $config = $new_config;
    }

    sub cfs_lock_file {
        my ($filename, $timeout, $code) = @_;
        $code->();
        $@ = '';
    }

    $INC{'PVE/Cluster.pm'} = 1;

    package PVE::RPCEnvironment;

    our $user = 'root@pam';

    sub get {
        return bless {}, __PACKAGE__;
    }

    sub get_user {
        return $user;
    }

    $INC{'PVE/RPCEnvironment.pm'} = 1;

    package PVE::RESTHandler;

    our %methods;

    sub import { }

    sub register_method {
        my ($class, $definition) = @_;
        $methods{$definition->{name}} = $definition;
    }

    $INC{'PVE/RESTHandler.pm'} = 1;
}

my $module = "$FindBin::Bin/../server/PVE/API2/ProxMorph.pm";
my $loaded = do $module;
ok($loaded, 'preferences API module loads with the Proxmox contracts stubbed')
    or diag($@ || $!);

is(
    $PVE::Cluster::registered_file,
    'priv/proxmorph-user-preferences.json',
    'preferences use one private replicated cluster file',
);

my $get = $PVE::RESTHandler::methods{get_preferences};
my $put = $PVE::RESTHandler::methods{set_preferences};
ok($get->{protected}, 'preference reads use the protected API path');
ok($put->{protected}, 'preference writes use the protected API path');
is_deeply($put->{permissions}, { user => 'all' }, 'any authenticated account may save its own settings');

my $root_defaults = $get->{code}->({});
is($root_defaults->{groupByNode}, 1, 'node hierarchy is enabled by default');
is($root_defaults->{showStorage}, 0, 'guest inventory excludes storage by default');
is($root_defaults->{showNetwork}, 0, 'guest inventory excludes connectivity by default');
is($root_defaults->{uiFont}, 'default', 'the native Proxmox font remains the safe default');
is($root_defaults->{uiTextSize}, 'default', 'the native 13 px scale remains the safe default');
is_deeply(
    $put->{parameters}->{properties}->{uiFont}->{enum},
    [qw(default modern)],
    'the API constrains account font choices',
);
is_deeply(
    $put->{parameters}->{properties}->{uiTextSize}->{enum},
    [qw(default comfortable large)],
    'the API constrains account text-size choices',
);

$put->{code}->({
    groupByNode => 0,
    showPools => 1,
    useIconNavigation => 1,
    uiFont => 'modern',
    uiTextSize => 'comfortable',
});

is(
    $PVE::Cluster::config->{users}->{'root@pam'}->{groupByNode},
    0,
    'settings are saved under the authenticated username',
);
is(
    $get->{code}->({})->{useIconNavigation},
    1,
    'saved settings are returned to the same account',
);
is($get->{code}->({})->{uiFont}, 'modern', 'the selected font follows the same account');
is(
    $get->{code}->({})->{uiTextSize},
    'comfortable',
    'the selected text size follows the same account',
);

$PVE::RPCEnvironment::user = 'operator@pve';
my $operator_defaults = $get->{code}->({});
is($operator_defaults->{groupByNode}, 1, 'another account receives independent defaults');
is($operator_defaults->{useIconNavigation}, 0, 'another account cannot read the first account settings');
is($operator_defaults->{uiFont}, 'default', 'another account keeps its own font preference');

$PVE::Cluster::config->{users}->{'operator@pve'}->{uiFont} = 'unsupported';
$PVE::Cluster::config->{users}->{'operator@pve'}->{uiTextSize} = 'huge';
my $operator_recovered = $get->{code}->({});
is($operator_recovered->{uiFont}, 'default', 'an unsupported stored font falls back safely');
is($operator_recovered->{uiTextSize}, 'default', 'an unsupported stored size falls back safely');

done_testing();
