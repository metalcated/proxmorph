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

$put->{code}->({
    groupByNode => 0,
    showPools => 1,
    useIconNavigation => 1,
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

$PVE::RPCEnvironment::user = 'operator@pve';
my $operator_defaults = $get->{code}->({});
is($operator_defaults->{groupByNode}, 1, 'another account receives independent defaults');
is($operator_defaults->{useIconNavigation}, 0, 'another account cannot read the first account settings');

done_testing();
