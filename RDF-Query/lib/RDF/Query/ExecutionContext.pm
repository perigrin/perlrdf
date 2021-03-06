# RDF::Query::ExecutionContext
# -----------------------------------------------------------------------------

=head1 NAME

RDF::Query::ExecutionContext - Query execution context

=head1 VERSION

This document describes RDF::Query::ExecutionContext version 2.902.

=head1 METHODS

=over 4

=cut

package RDF::Query::ExecutionContext;

use strict;
use warnings;

######################################################################

our ($VERSION);
BEGIN {
	$VERSION	= '2.902';
}

######################################################################

=item C<< new ( model => $model, query => $query, bound => \%bound ) >>

=cut

sub new {
	my $class	= shift;
	my %args	= @_;
	my $self	= bless( [{ %args }], $class );
	return $self;
}

=item C<< copy ( %new_args ) >>

=cut

sub copy {
	my $self	= shift;
	my %args	= @_;
	my $class	= ref($self);
	my @data;
	foreach my $i (0 .. $#{ $self }) {
		push(@data, { %{ $self->[$i] } });
	}
	@{ $data[0] }{ keys %args }	= values %args;
	return bless( \@data, $class );
}

=item C<< pushstack >>

=cut

sub pushstack {
	my $self	= shift;
	unshift( @{ $self }, {} );
}

=item C<< popstack >>

=cut

sub popstack {
	my $self	= shift;
	shift( @{ $self } );
}

=item C<< model >>

=cut

sub model {
	my $self	= shift;
	my $model	= $self->_get_value( 'model', @_ );
	unless ($model) {
		$model	= RDF::Trine::Model->temporary_model;
	}
	return $model;
}

=item C<< query >>

=cut

sub query {
	my $self	= shift;
	return $self->_get_value( 'query', @_ );
}

=item C<< bound >>

=cut

sub bound {
	my $self	= shift;
	return $self->_get_value( 'bound', @_ ) || {};
}

=item C<< base >>

=cut

sub base {
	my $self	= shift;
	return $self->_get_value( 'base', @_ ) || {};
}

=item C<< ns >>

=cut

sub ns {
	my $self	= shift;
	return $self->_get_value( 'ns', @_ ) || {};
}

=item C<< logger >>

=cut

sub logger {
	my $self	= shift;
	return $self->_get_value( 'logger', @_ );
}

=item C<< costmodel >>

=cut

sub costmodel {
	my $self	= shift;
	return $self->_get_value( 'costmodel', @_ );
}

=item C<< requested_variables >>

=cut

sub requested_variables {
	my $self	= shift;
	return $self->_get_value( 'requested_variables', @_ );
}

=item C<< optimize >>

=cut

sub optimize {
	my $self	= shift;
	return $self->_get_value( 'optimize', @_ );
}

=item C<< strict_errors >>

=cut

sub strict_errors {
	my $self	= shift;
	return $self->_get_value( 'strict_errors', @_ );
}

=item C<< optimistic_threshold_time >>

=cut

sub optimistic_threshold_time {
	my $self	= shift;
	return $self->_get_value( 'optimistic_threshold_time', @_ );
}

sub _get_value {
	my $self	= shift;
	my $key		= shift;
	if (@_) {
		$self->[0]{ $key }	= shift;
	}
	foreach my $i (0 .. $#{ $self }) {
		if (exists($self->[ $i ]{ $key })) {
			return $self->[ $i ]{ $key };
		}
	}
	return;
}

1;

__END__

=back

=head1 AUTHOR

 Gregory Todd Williams <gwilliams@cpan.org>

=cut
