package CPAN::Meta::Merge;

use Scalar::Util qw/blessed/;
use Carp qw/croak/;
use CPAN::Meta::Prereqs;
use Hash::Merge::Simple;

use Moo 1.000008;

has version => (
	is       => 'ro',
	required => 1,
);

sub croaker {
	my (undef, undef, $path) = @_;
	croak "Can't merge attribute " . join '.', @{$path};
}

sub _merge {
	my ($current, $next, $mergers, $path) = @_;
	for my $key (keys %{$next}) {
		if (not exists $current->{$key}) {
			$current->{$key} = $next->{$key};
		}
		elsif (my $merger = $mergers->{$key}) {
			$current->{$key} = $merger->($current->{$key}, $next->{$key}, [ @{$path}, $key ]);
		}
		elsif ($merger = $mergers->{':default'}) {
			$current->{$key} = $merger->($current->{$key}, $next->{$key}, [ @{$path}, $key ]);
		}
		else {
			croak sprintf "Can't merge '%s'", join '.', @{$path}, $key;
		}
	}
	return $current;
}

sub concat_list {
	my ($left, $right) = @_;
	return [ @{$left}, @{$right} ];
}

sub deep_merge {
	my ($left, $right) = @_;
	return Hash::Merge::Simple::merge($left, $right);
}

sub uniq_map {
	my ($left, $right, $path) = @_;
	for my $key (keys %{$right}) {
		if (not exists $left->{$key}) {
			$left->{$key} = $right->{$key};
		}
		else {
			croak 'Duplication of element ' . join '.', @{$path}, $key;
		}
	}
	return $left;
}

my %default = (
	abstract       => \&croaker,
	authors        => \&concat_list,
	dynamic_config => sub {
		my ($left, $right) = @_;
		return $left || $right;
	},
	generated_by => \&croaker,       # concat_string?
	license      => \&concat_list,
	'meta-spec'  => sub {
		my ($left, $right) = @_;
		croak 'Trying to merge differently versioned meta fragments' if $left->{version} != $right->{version};
		return { %{$left}, %{$right} };
	},
	name           => \&croaker,
	release_status => \&croaker,
	version        => \&croaker,
	description    => \&croaker,
	keywords       => \&concat_list,
	no_index       => { map { ( $_ => \&concat_list) } qw/file directory package namespace/ },
	optional_features => \&uniq_map,
	prereqs           => sub {
		my ($left, $right) = map { CPAN::Meta::Prereqs->new($_) } @_[0,1];
		return $left->with_merged_prereqs($right)->as_string_hash;
	},
	provides  => \&uniq_map,
	resources => {
		license => \&concat_list,
		homepage => \&croaker,
		bugtracker => \&uniq_map,
		repository => \&uniq_map,
	},
	':default' => 1 ? \&croaker : sub {
		my ($left, $right, $path) = @_;
		if (ref($left) eq 'ARRAY') {
			return concat_list($left, $right, $path);
		}
		elsif (ref($left) eq 'HASH') {
			return deep_merge($left, $right, $path);
		}
		else {
			croak sprintf "Can't merge '%s'", join '.', @{$path};
		}
	},
);

has _mapping => (
	is       => 'lazy',
	init_arg => undef,
	builder  => sub {
		my $self = shift;
		return { %default, %{ $self->_extra_mappings } };
	},
	coerce   => sub {
		return _coerce_mapping($_[0], []);
	}
);

my %coderef_for = (
	concat_list => \&concat_list,
	deep_merge  => \&deep_merge,
	uniq_map    => \&uniq_map,
	croak       => \&croaker,
);

sub _coerce_mapping {
	my ($orig, $map_path) = @_;
	my %ret;
	for my $key (keys %{$orig}) {
		my $value = $orig->{$key};
		if (ref($orig->{$key}) eq 'CODE') {
			$ret{$key} = $value;
		}
		elsif (ref($value) eq 'HASH') {
			my $mapping = _coerce_mapping($value, [ @{$map_path}, $key ]);
			$ret{$key} = sub {
				my ($left, $right, $path) = @_;
				return _merge($left, $right, $mapping, [ @{$path}, $key ]);
			};
		}
		elsif ($coderef_for{$value}) {
			$ret{$key} = $coderef_for{$value};
		}
		else {
			croak "Don't know what to do with " . join '.', @{$map_path}, $key;
		}
	}
	return \%ret;
}

has _extra_mappings => (
	is       => 'ro',
	init_arg => 'extra_mappings',
	default  => sub { {} },
);

sub merge {
	my ($self, @items) = @_;
	my $current = {};
	for my $next (@items) {
		$next = $next->as_string_hash if blessed($next);
		$current = _merge($current, $next, $self->_mapping, []);
	}
	return $current;
}

1;

# ABSTRACT: Merging CPAN Meta fragments
