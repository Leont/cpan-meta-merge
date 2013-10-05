package CPAN::Meta::Merge;

use Carp qw/croak/;
use CPAN::Meta::Prereqs;
use List::MoreUtils qw/uniq/;
use Scalar::Util qw/blessed/;

use Moo 1.000008;

has version => (
	is       => 'ro',
	required => 1,
);

sub identical {
	my ($left, $right, $path) = @_;
	croak "Can't merge attribute " . join '.', @{$path} unless $left eq $right;
	return $left;
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

sub set_addition {
	my ($left, $right) = @_;
	return [ sort +uniq(@{$left}, @{$right}) ];
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

sub improvize {
	my ($left, $right, $path) = @_;
	my ($name) = reverse @{$path};
	if ($name =~ /^x_/) {
		if (ref($left) eq 'ARRAY') {
			return set_addition($left, $right, $path);
		}
		elsif (ref($left) eq 'HASH') {
			return uniq_map($left, $right, $path);
		}
		else {
			return identical($left, $right, $path);
		}
	}
	croak sprintf "Can't merge '%s'", join '.', @{$path};
}

my %default = (
	abstract       => \&identical,
	authors        => \&set_addition,
	dynamic_config => sub {
		my ($left, $right) = @_;
		return $left || $right;
	},
	generated_by => sub {
		my ($left, $right) = @_;
		return $left eq $right ? $left : "$left, $right";
	},
	license     => \&set_addition,
	'meta-spec' => {
		version => \&identical,
		url     => \&identical
	},
	name              => \&identical,
	release_status    => \&identical,
	version           => \&identical,
	description       => \&identical,
	keywords          => \&set_addition,
	no_index          => { map { ($_ => \&set_addition) } qw/file directory package namespace/ },
	optional_features => \&uniq_map,
	prereqs           => sub {
		my ($left, $right) = map { CPAN::Meta::Prereqs->new($_) } @_[0,1];
		return $left->with_merged_prereqs($right)->as_string_hash;
	},
	provides  => \&uniq_map,
	resources => {
		license    => \&set_addition,
		homepage   => \&identical,
		bugtracker => \&uniq_map,
		repository => \&uniq_map,
		':default' => \&improvize,
	},
	':default' => \&improvize,
);

has _mapping => (
	is       => 'lazy',
	init_arg => undef,
	builder  => sub {
		my $self = shift;
		return { %default, %{ $self->_extra_mappings } };
	},
	coerce => sub {
		return _coerce_mapping($_[0], []);
	}
);

my %coderef_for = (
	set_addition => \&set_addition,
	uniq_map     => \&uniq_map,
	identical    => \&identical,
	improvize    => \&improvize,
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
