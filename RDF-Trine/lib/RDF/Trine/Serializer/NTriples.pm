# RDF::Trine::Serializer::NTriples
# -----------------------------------------------------------------------------

=head1 NAME

RDF::Trine::Serializer::NTriples - N-Triples Serializer.

=head1 VERSION

This document describes RDF::Trine::Serializer::NTriples version 0.121

=head1 SYNOPSIS

 use RDF::Trine::Serializer::NTriples;
 my $serializer	= RDF::Trine::Serializer::NTriples->new();

=head1 DESCRIPTION

The RDF::Trine::Serializer::NTriples class provides an API for serializing RDF
graphs to the N-Triples syntax.

=head1 METHODS

=over 4

=cut

package RDF::Trine::Serializer::NTriples;

use strict;
use warnings;
use base qw(RDF::Trine::Serializer);

use URI;
use Carp;
use XML::SAX;
use Data::Dumper;
use Scalar::Util qw(blessed);

use RDF::Trine::Node;
use RDF::Trine::Statement;
use RDF::Trine::Error qw(:try);

######################################################################

our ($VERSION);
BEGIN {
	$VERSION	= '0.121';
	$RDF::Trine::Serializer::serializer_names{ 'ntriples' }	= __PACKAGE__;
	foreach my $type (qw(text/plain)) {
		$RDF::Trine::Serializer::media_types{ $type }	= __PACKAGE__;
	}
}

######################################################################

=item C<< new >>

Returns a new N-Triples serializer object.

=cut

sub new {
	my $class	= shift;
	my %args	= @_;
	my $self = bless( {}, $class);
	return $self;
}

=item C<< serialize_model_to_file ( $fh, $model ) >>

Serializes the C<$model> to N-Triples, printing the results to the supplied
filehandle C<<$fh>>.

=cut

sub serialize_model_to_file {
	my $self	= shift;
	my $file	= shift;
	my $model	= shift;
	my $iter	= $model->as_stream;
	while (my $st = $iter->next) {
		print {$file} $self->_statement_as_string( $st );
	}
}

=item C<< serialize_model_to_string ( $model ) >>

Serializes the C<$model> to N-Triples, returning the result as a string.

=cut

sub serialize_model_to_string {
	my $self	= shift;
	my $model	= shift;
	my $iter	= $model->as_stream;
	my $string	= '';
	while (my $st = $iter->next) {
		my @nodes	= $st->nodes;
		$string		.= $self->_statement_as_string( $st );
	}
	return $string;
}

=item C<< serialize_iterator_to_file ( $file, $iter ) >>

Serializes the iterator to N-Triples, printing the results to the supplied
filehandle C<<$fh>>.

=cut

sub serialize_iterator_to_file {
	my $self	= shift;
	my $file	= shift;
	my $iter	= shift;
	while (my $st = $iter->next) {
		print {$file} $self->_statement_as_string( $st );
	}
}

=item C<< serialize_iterator_to_string ( $iter ) >>

Serializes the iterator to N-Triples, returning the result as a string.

=cut

sub serialize_iterator_to_string {
	my $self	= shift;
	my $iter	= shift;
	my $string	= '';
	while (my $st = $iter->next) {
		my @nodes	= $st->nodes;
		$string		.= $self->_statement_as_string( $st );
	}
	return $string;
}

sub _serialize_bounded_description {
	my $self	= shift;
	my $model	= shift;
	my $node	= shift;
	my $seen	= shift || {};
	return '' if ($seen->{ $node->sse }++);
	my $iter	= $model->get_statements( $node, undef, undef );
	my $string	= '';
	while (my $st = $iter->next) {
		my @nodes	= $st->nodes;
		$string		.= $self->_statement_as_string( $st );
		if ($nodes[2]->is_blank) {
			$string	.= $self->_serialize_bounded_description( $model, $nodes[2], $seen );
		}
	}
	return $string;
}

sub _statement_as_string {
	my $self	= shift;
	my $st		= shift;
	return join(' ', map { $_->as_ntriples } $st->nodes) . " .\n";
}

1;

__END__

=back

=head1 SEE ALSO

L<http://www.w3.org/TR/rdf-testcases/#ntriples>

=head1 AUTHOR

Gregory Todd Williams  C<< <gwilliams@cpan.org> >>

=head1 COPYRIGHT

Copyright (c) 2006-2010 Gregory Todd Williams. All rights reserved. This
program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
