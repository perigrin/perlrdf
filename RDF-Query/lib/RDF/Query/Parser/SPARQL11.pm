# RDF::Query::Parser::SPARQL11
# -----------------------------------------------------------------------------

=head1 NAME

RDF::Query::Parser::SPARQL11 - SPARQL 1.1 Parser.

=head1 VERSION

This document describes RDF::Query::Parser::SPARQL11 version 2.902.

=head1 SYNOPSIS

 use RDF::Query::Parser::SPARQL11;
 my $parser	= RDF::Query::Parse::SPARQL11->new();
 my $iterator = $parser->parse( $query, $base_uri );

=head1 DESCRIPTION

...

=head1 METHODS

=over 4

=cut

package RDF::Query::Parser::SPARQL11;

use strict;
use warnings;
no warnings 'redefine';
use base qw(RDF::Query::Parser);

use URI;
use Data::Dumper;
use RDF::Query::Error qw(:try);
use RDF::Query::Parser;
use RDF::Query::Algebra;
use RDF::Trine::Namespace qw(rdf);
use Scalar::Util qw(blessed looks_like_number reftype);

######################################################################

our ($VERSION);
BEGIN {
	$VERSION	= '2.902';
}

######################################################################

my $rdf			= RDF::Trine::Namespace->new('http://www.w3.org/1999/02/22-rdf-syntax-ns#');
my $xsd			= RDF::Trine::Namespace->new('http://www.w3.org/2001/XMLSchema#');

our $r_ECHAR				= qr/\\([tbnrf\\"'])/;
our $r_STRING_LITERAL1		= qr/'(([^\x{27}\x{5C}\x{0A}\x{0D}])|${r_ECHAR})*'/;
our $r_STRING_LITERAL2		= qr/"(([^\x{22}\x{5C}\x{0A}\x{0D}])|${r_ECHAR})*"/;
our $r_STRING_LITERAL_LONG1	= qr/'''(('|'')?([^'\\]|${r_ECHAR}))*'''/;
our $r_STRING_LITERAL_LONG2	= qr/"""(("|"")?([^"\\]|${r_ECHAR}))*"""/;
our $r_LANGTAG				= qr/@[a-zA-Z]+(-[a-zA-Z0-9]+)*/;
our $r_IRI_REF				= qr/<([^<>"{}|^`\\\x{00}-\x{20}])*>/;
our $r_PN_CHARS_BASE		= qr/([A-Z]|[a-z]|[\x{00C0}-\x{00D6}]|[\x{00D8}-\x{00F6}]|[\x{00F8}-\x{02FF}]|[\x{0370}-\x{037D}]|[\x{037F}-\x{1FFF}]|[\x{200C}-\x{200D}]|[\x{2070}-\x{218F}]|[\x{2C00}-\x{2FEF}]|[\x{3001}-\x{D7FF}]|[\x{F900}-\x{FDCF}]|[\x{FDF0}-\x{FFFD}]|[\x{10000}-\x{EFFFF}])/;
our $r_PN_CHARS_U			= qr/(_|${r_PN_CHARS_BASE})/;
our $r_VARNAME				= qr/((${r_PN_CHARS_U}|[0-9])(${r_PN_CHARS_U}|[0-9]|\x{00B7}|[\x{0300}-\x{036F}]|[\x{203F}-\x{2040}])*)/;
our $r_VAR1					= qr/[?]${r_VARNAME}/;
our $r_VAR2					= qr/[\$]${r_VARNAME}/;
our $r_PN_CHARS				= qr/${r_PN_CHARS_U}|-|[0-9]|\x{00B7}|[\x{0300}-\x{036F}]|[\x{203F}-\x{2040}]/;
our $r_PN_PREFIX			= qr/(${r_PN_CHARS_BASE}((${r_PN_CHARS}|[.])*${r_PN_CHARS})?)/;
our $r_PN_LOCAL				= qr/((${r_PN_CHARS_U}|[0-9])((${r_PN_CHARS}|[.])*${r_PN_CHARS})?)/;
our $r_PNAME_NS				= qr/((${r_PN_PREFIX})?:)/;
our $r_PNAME_LN				= qr/(${r_PNAME_NS}${r_PN_LOCAL})/;
our $r_EXPONENT				= qr/[eE][-+]?\d+/;
our $r_DOUBLE				= qr/\d+[.]\d*${r_EXPONENT}|[.]\d+${r_EXPONENT}|\d+${r_EXPONENT}/;
our $r_DECIMAL				= qr/(\d+[.]\d*)|([.]\d+)/;
our $r_INTEGER				= qr/\d+/;
our $r_BLANK_NODE_LABEL		= qr/_:${r_PN_LOCAL}/;
our $r_ANON					= qr/\[[\t\r\n ]*\]/;
our $r_NIL					= qr/\([\n\r\t ]*\)/;
our $r_AGGREGATE_CALL		= qr/MIN|MAX|COUNT|AVG|SUM|SAMPLE|GROUP_CONCAT/i;

=item C<< new >>

Returns a new Turtle parser.

=cut

sub new {
	my $class	= shift;
	my $self	= bless({
					bindings	=> {},
					bnode_id	=> 0,
				}, $class);
	return $self;
}

################################################################################

=item C<< parse ( $query, $base_uri, $update_flag ) >>

Parses the C<< $query >>, using the given C<< $base_uri >>.
If C<< $update_flag >> is true, the query will be parsed allowing
SPARQL 1.1 Update statements.

=cut

sub parse {
	my $self	= shift;
	my $input	= shift;
	my $baseuri	= shift;
	my $update	= shift || 0;
	
	$input		=~ s/\\u([0-9A-Fa-f]{4})/chr(hex($1))/ge;
	$input		=~ s/\\U([0-9A-Fa-f]{8})/chr(hex($1))/ge;
	
	delete $self->{error};
	local($self->{namespaces})				= {};
	local($self->{blank_ids})				= 1;
	local($self->{baseURI})					= $baseuri;
	local($self->{tokens})					= $input;
	local($self->{stack})					= [];
	local($self->{filters})					= [];
	local($self->{pattern_container_stack})	= [];
	local($self->{update})					= $update;
	my $triples								= $self->_push_pattern_container();
	$self->{build}							= { sources => [], triples => $triples };
	if ($baseuri) {
		$self->{build}{base}	= $baseuri;
	}
	
	try {
		$self->_RW_Query();
	} catch RDF::Query::Error with {
		my $e	= shift;
		$self->{build}	= undef;
		$self->{error}	= $e->stacktrace
	};
	my $data								= delete $self->{build};
#	$data->{triples}						= $self->_pop_pattern_container();
	return $data;
}

=item C<< parse_pattern ( $pattern, $base_uri, \%namespaces ) >>

Parses the C<< $pattern >>, using the given C<< $base_uri >> and returns a
RDF::Query::Algebra pattern.

=cut

sub parse_pattern {
	my $self	= shift;
	my $input	= shift;
	my $baseuri	= shift;
	my $ns		= shift;
	
	$input		=~ s/\\u([0-9A-Fa-f]{4})/chr(hex($1))/ge;
	$input		=~ s/\\U([0-9A-Fa-f]{8})/chr(hex($1))/ge;
	
	delete $self->{error};
	local($self->{namespaces})				= $ns;
	local($self->{blank_ids})				= 1;
	local($self->{baseURI})					= $baseuri;
	local($self->{tokens})					= $input;
	local($self->{stack})					= [];
	local($self->{filters})					= [];
	local($self->{pattern_container_stack})	= [];
	my $triples								= $self->_push_pattern_container();
	$self->{build}							= { sources => [], triples => $triples };
	if ($baseuri) {
		$self->{build}{base}	= $baseuri;
	}
	
	try {
		$self->_GroupGraphPattern();
	} catch RDF::Query::Error with {
		my $e	= shift;
		$self->{build}	= undef;
		$self->{error}	= $e->text;
	};
	my $data								= delete $self->{build};
	
	return $data->{triples}[0];
}

=item C<< parse_expr ( $pattern, $base_uri, \%namespaces ) >>

Parses the C<< $pattern >>, using the given C<< $base_uri >> and returns a
RDF::Query::Expression pattern.

=cut

sub parse_expr {
	my $self	= shift;
	my $input	= shift;
	my $baseuri	= shift;
	my $ns		= shift;
	
	$input		=~ s/\\u([0-9A-Fa-f]{4})/chr(hex($1))/ge;
	$input		=~ s/\\U([0-9A-Fa-f]{8})/chr(hex($1))/ge;
	
	delete $self->{error};
	local($self->{namespaces})				= $ns;
	local($self->{blank_ids})				= 1;
	local($self->{baseURI})					= $baseuri;
	local($self->{tokens})					= $input;
	local($self->{stack})					= [];
	local($self->{filters})					= [];
	local($self->{pattern_container_stack})	= [];
	my $triples								= $self->_push_pattern_container();
	$self->{build}							= { sources => [], triples => $triples };
	if ($baseuri) {
		$self->{build}{base}	= $baseuri;
	}
	
	try {
		$self->_Expression();
	} catch RDF::Query::Error with {
		my $e	= shift;
		$self->{build}	= undef;
		$self->{error}	= $e->text;
	};
	
	my $data	= splice(@{ $self->{stack} });
	return $data;
}

################################################################################


# [1] Query ::= Prologue ( SelectQuery | ConstructQuery | DescribeQuery | AskQuery | LoadUpdate )
sub _RW_Query {
	my $self	= shift;
	$self->__consume_ws_opt;
	$self->_Prologue;
	$self->__consume_ws_opt;
	
	my $read_query	= 0;
	while (1) {
		if ($self->_test(qr/SELECT/i)) {
			$self->_SelectQuery();
			$read_query++;
		} elsif ($self->_test(qr/CONSTRUCT/i)) {
			$self->_ConstructQuery();
			$read_query++;
		} elsif ($self->_test(qr/DESCRIBE/i)) {
			$self->_DescribeQuery();
			$read_query++;
		} elsif ($self->_test(qr/ASK/i)) {
			$self->_AskQuery();
			$read_query++;
		} elsif ($self->_test(qr/CREATE\s+(SILENT\s+)?GRAPH/i)) {
			throw RDF::Query::Error::PermissionError -text => "CREATE GRAPH update forbidden in read-only queries"
				unless ($self->{update});
			$self->_CreateGraph();
		} elsif ($self->_test(qr/DROP\s+(SILENT\s+)?GRAPH/i)) {
			throw RDF::Query::Error::PermissionError -text => "DROP GRAPH update forbidden in read-only queries"
				unless ($self->{update});
			$self->_DropGraph();
		} elsif ($self->_test(qr/LOAD/i)) {
			throw RDF::Query::Error::PermissionError -text => "LOAD update forbidden in read-only queries"
				unless ($self->{update});
			$self->_LoadUpdate();
# 			warn Dumper($self->{build});
		} elsif ($self->_test(qr/CLEAR\s+GRAPH/i)) {
			throw RDF::Query::Error::PermissionError -text => "CLEAR GRAPH update forbidden in read-only queries"
				unless ($self->{update});
			$self->_ClearGraphUpdate();
		} elsif ($self->_test(qr/INSERT\s+DATA/i)) {
			throw RDF::Query::Error::PermissionError -text => "INSERT DATA update forbidden in read-only queries"
				unless ($self->{update});
			$self->_InsertDataUpdate();
		} elsif ($self->_test(qr/DELETE\s+DATA/i)) {
			throw RDF::Query::Error::PermissionError -text => "DELETE DATA update forbidden in read-only queries"
				unless ($self->{update});
			$self->_DeleteDataUpdate();
# 		} elsif ($self->_test(qr/DELETE\s+WHERE/i)) {
# 			throw RDF::Query::Error::PermissionError -text => "DELETE WHERE update forbidden in read-only queries"
# 				unless ($self->{update});
# 			$self->_DeleteWhereUpdate();
		} elsif ($self->_test(qr/(WITH|INSERT|DELETE)/i)) {
			throw RDF::Query::Error::PermissionError -text => "INSERT/DELETE update forbidden in read-only queries"
				unless ($self->{update});
			if ($self->_test(qr/(WITH\s*${r_IRI_REF}\s*)?INSERT/i)) {
				$self->_InsertUpdate();
			} elsif ($self->_test(qr/(WITH\s*${r_IRI_REF}\s*)?DELETE/i)) {
				$self->_DeleteUpdate();
			}
		} else {
			my $l		= Log::Log4perl->get_logger("rdf.query");
			if ($l->is_debug) {
				$l->logcluck("Syntax error: Expected query type with input <<$self->{tokens}>>");
			}
			throw RDF::Query::Error::ParseError -text => 'Syntax error: Expected query type';
		}
		last if ($read_query);
		$self->__consume_ws_opt;
		if ($self->_test(qr/;/)) {
			$self->_eat(qr/;/) ;
			$self->__consume_ws_opt;
			if ($self->_Query_test) {
				next;
			}
		}
		last;
	}
	$self->_eat(qr/;/) if ($self->_test(qr/;/));
	$self->__consume_ws_opt;
	
	my $count	= scalar(@{ $self->{build}{triples} });
	my $remaining	= $self->{tokens};
	if ($remaining =~ m/\S/) {
		throw RDF::Query::Error::ParseError -text => "Syntax error: Remaining input after query: $remaining";
	}
	
	if ($count > 1) {
		my @patterns	= splice(@{ $self->{build}{triples} });
		$self->{build}{triples}	= [ RDF::Query::Algebra::Sequence->new( @patterns ) ];
	}
	
# 	my %query	= (%p, %body);
# 	return \%query;
}

sub _Query_test {
	my $self	= shift;
	return 1 if ($self->_test(qr/SELECT|CONSTRUCT|DESCRIBE|ASK|LOAD|CLEAR|INSERT|DELETE|WITH/i));
	return 0;
}

# [2] Prologue ::= BaseDecl? PrefixDecl*
# [3] BaseDecl ::= 'BASE' IRI_REF
# [4] PrefixDecl ::= 'PREFIX' PNAME_NS IRI_REF
sub _Prologue {
	my $self	= shift;
	
	my $base;
	my @base;
	if ($self->_test( qr/BASE/i )) {
		$self->_eat( qr/BASE/i );
		$self->__consume_ws_opt;
		my $iriref	= $self->_eat( $r_IRI_REF );
		my $iri		= substr($iriref,1,length($iriref)-2);
		$base		= RDF::Query::Node::Resource->new( $iri );
		@base		= $base;
		$self->__consume_ws_opt;
		$self->{base}	= $base;
	}
	
	my %namespaces;
	while ($self->_test( qr/PREFIX/i )) {
		$self->_eat( qr/PREFIX/i );
		$self->__consume_ws_opt;
		my $prefix	= $self->_eat( $r_PNAME_NS );
		my $ns		= substr($prefix, 0, length($prefix) - 1);
		if ($ns eq '') {
			$ns	= '__DEFAULT__';
		}
		$self->__consume_ws_opt;
		my $iriref	= $self->_eat( $r_IRI_REF );
		my $iri		= substr($iriref,1,length($iriref)-2);
		if (@base) {
			my $r	= RDF::Query::Node::Resource->new( $iri, @base );
			$iri	= $r->uri_value;
		}
		$self->__consume_ws_opt;
		$namespaces{ $ns }	= $iri;
		$self->{namespaces}{$ns}	= $iri;
	}
	
	$self->{build}{namespaces}	= \%namespaces;
	$self->{build}{base}		= $base if (defined($base));
	
# 	push(@data, (base => $base)) if (defined($base));
# 	return @data;
}

sub _InsertDataUpdate {
	my $self	= shift;
	$self->_eat(qr/INSERT\s+DATA/i);
	$self->__consume_ws_opt;
	$self->_eat('{');
	$self->__consume_ws_opt;
	$self->_ModifyTemplate();
	$self->__consume_ws_opt;
	my $data	= $self->_remove_pattern;
	$self->_eat('}');
	$self->__consume_ws_opt;
	
	my $empty	= RDF::Query::Algebra::GroupGraphPattern->new();
	my $insert	= RDF::Query::Algebra::Update->new(undef, $data, $empty);
	$self->_add_patterns( $insert );
	$self->{build}{method}		= 'UPDATE';
}

sub _DeleteDataUpdate {
	my $self	= shift;
	$self->_eat(qr/DELETE\s+DATA/i);
	$self->__consume_ws_opt;
	$self->_eat('{');
	$self->__consume_ws_opt;
	$self->_ModifyTemplate();
	$self->__consume_ws_opt;
	my $data	= $self->_remove_pattern;
	$self->_eat('}');
	$self->__consume_ws_opt;
	
	my $empty	= RDF::Query::Algebra::GroupGraphPattern->new();
	my $delete	= RDF::Query::Algebra::Update->new($data, undef, $empty);
	$self->_add_patterns( $delete );
	$self->{build}{method}		= 'UPDATE';
}

sub _InsertUpdate {
	my $self	= shift;
	my ($graph);
	if ($self->_test(qr/WITH/i)) {
		$self->_eat(qr/WITH/i);
		$self->__consume_ws_opt;
		my $iri	= $self->_eat( $r_IRI_REF );
		$graph	= RDF::Query::Node::Resource->new( substr($iri,1,length($iri)-2), $self->__base );
		$self->__consume_ws_opt;
	}
	$self->_eat(qr/INSERT/i);
	$self->__consume_ws_opt;
	$self->_eat('{');
	$self->__consume_ws_opt;
	$self->_ModifyTemplate();
	$self->__consume_ws_opt;
	my $data	= $self->_remove_pattern;
	$self->_eat('}');
	$self->__consume_ws_opt;
	if ($graph) {
		$data	= RDF::Query::Algebra::NamedGraph->new( $graph, $data );
	}

	
	my %dataset;
	while ($self->_test(qr/USING/i)) {
		$self->_eat(qr/USING/i);
		$self->__consume_ws_opt;
		my $named	= 0;
		if ($self->_test(qr/NAMED/i)) {
			$self->_eat(qr/NAMED/i);
			$self->__consume_ws_opt;
			$named	= 1;
		}
		$self->_IRIref;
		my ($iri)	= splice( @{ $self->{stack} } );
		if ($named) {
			$dataset{named}{$iri->uri_value}	= $iri;
		} else {
			push(@{ $dataset{default} }, $iri );
		}
		$self->__consume_ws_opt;
	}
	
	$self->_eat(qr/WHERE/i);
	$self->__consume_ws_opt;
	$self->_GroupGraphPattern;
	my $ggp	= $self->_remove_pattern;
	
	my @ds_keys	= keys %dataset;
	unless (@ds_keys) {
		$dataset{ default }	= [$graph];
	}
	
	my $insert	= RDF::Query::Algebra::Update->new(undef, $data, $ggp, \%dataset);
	$self->_add_patterns( $insert );
	$self->{build}{method}		= 'UPDATE';
}

sub _DeleteUpdate {
	my $self	= shift;
	my $graph;
	my ($delete_data, $insert_data);
	
	if ($self->_test(qr/WITH/i)) {
		$self->_eat(qr/WITH/i);
		$self->__consume_ws_opt;
		my $iri	= $self->_eat( $r_IRI_REF );
		$graph	= RDF::Query::Node::Resource->new( substr($iri,1,length($iri)-2), $self->__base );
		$self->__consume_ws_opt;
	}
	$self->_eat(qr/DELETE/i);
	$self->__consume_ws_opt;
	my %dataset;
	my $delete_where	= 0;
	if ($self->_test(qr/WHERE/i)) {
		if ($graph) {
			throw RDF::Query::Error::ParseError -text => "Syntax error: WITH clause cannot be used with DELETE WHERE operations";
		}
		$delete_where	= 1;
	} else {
		$self->_eat('{');
		$self->__consume_ws_opt;
		$self->_ModifyTemplate( $graph );
		$self->__consume_ws_opt;
		$self->_eat('}');
		$delete_data	= $self->_remove_pattern;
		
		$self->__consume_ws_opt;
		if ($self->_test(qr/INSERT/i)) {
			$self->_eat(qr/INSERT/i);
			$self->__consume_ws_opt;
			$self->_eat('{');
			$self->__consume_ws_opt;
			$self->_ModifyTemplate( $graph );
			$self->__consume_ws_opt;
			$self->_eat('}');
			$self->__consume_ws_opt;
			$insert_data	= $self->_remove_pattern;
		}
		
		while ($self->_test(qr/USING/i)) {
			$self->_eat(qr/USING/i);
			$self->__consume_ws_opt;
			my $named	= 0;
			if ($self->_test(qr/NAMED/i)) {
				$self->_eat(qr/NAMED/i);
				$self->__consume_ws_opt;
				$named	= 1;
			}
			$self->_IRIref;
			my ($iri)	= splice( @{ $self->{stack} } );
			if ($named) {
				$dataset{named}{$iri->uri_value}	= $iri;
			} else {
				push(@{ $dataset{default} }, $iri );
			}
			$self->__consume_ws_opt;
		}
	}
	
	$self->_eat(qr/WHERE/i);
	$self->__consume_ws_opt;
	if ($graph) {
		local($self->{named_graph})	= $graph;
		$self->_GroupGraphPattern;
		my $ggp	= $self->_remove_pattern;
		$ggp	= RDF::Query::Algebra::NamedGraph->new( $graph, $ggp );
		$self->_add_patterns( $ggp );
	} else {
		$self->_GroupGraphPattern;
	}

	my $ggp	= $self->_remove_pattern;

	if ($delete_where) {
		$delete_data	= $ggp;
	}
	
	my @ds_keys	= keys %dataset;
	if ($graph and not(scalar(@ds_keys))) {
		$dataset{ default }	= [$graph];
	}
	
	my $insert	= RDF::Query::Algebra::Update->new($delete_data, $insert_data, $ggp, \%dataset);
	$self->_add_patterns( $insert );
	$self->{build}{method}		= 'UPDATE';
}

sub _ModifyTemplate_test {
	my $self	= shift;
	return 1 if ($self->_TriplesBlock_test);
	return 1 if ($self->_test(qr/GRAPH/i));
	return 0;
}

sub _ModifyTemplate {
	my $self	= shift;
	my $graph	= shift;
	
	local($self->{named_graph});
	if ($graph) {
		$self->{named_graph}	= $graph;
	}
	
	$self->__ModifyTemplate;
	$self->__consume_ws_opt;
	my $data	= $self->_remove_pattern;
	$data	= RDF::Query::Algebra::GroupGraphPattern->new( $data ) unless ($data->isa('RDF::Query::Algebra::GroupGraphPattern'));
	while ($self->_ModifyTemplate_test) {
		$self->__ModifyTemplate( $graph );
		$self->__consume_ws_opt;
		my $d			= $self->_remove_pattern;
		my @patterns	= $data->patterns;
		$data			= RDF::Query::Algebra::GroupGraphPattern->new( @patterns, $d );
	}
	$data	= RDF::Query::Algebra::GroupGraphPattern->new( $data ) unless ($data->isa('RDF::Query::Algebra::GroupGraphPattern'));
	$self->_add_patterns( $data );
}

sub __ModifyTemplate {
	my $self	= shift;
	my $graph	= shift;
	if ($self->_TriplesBlock_test) {
		my $data;
		$self->_push_pattern_container;
		$self->_TriplesBlock;
		($data)	= @{ $self->_pop_pattern_container };
		if ($graph) {
			my $ggp	= RDF::Query::Algebra::GroupGraphPattern->new( $data );
			my $data	= RDF::Query::Algebra::NamedGraph->new( $graph, $ggp );
		}
		$self->_add_patterns( $data );
	} else {
		$self->_GraphGraphPattern;
		{
			my ($d)	= splice(@{ $self->{stack} });
			$self->__handle_GraphPatternNotTriples( $d );
		}
	}
}

sub _LoadUpdate {
	my $self	= shift;
	$self->_eat(qr/LOAD/i);
	$self->_ws;
	$self->_IRIref;
	my ($iri)	= splice( @{ $self->{stack} } );
	$self->__consume_ws_opt;
	if ($self->_test(qr/INTO GRAPH/i)) {
		$self->_eat(qr/INTO GRAPH/i);
		$self->_ws;
		$self->_IRIref;
		my ($graph)	= splice( @{ $self->{stack} } );
		my $pat	= RDF::Query::Algebra::Load->new( $iri, $graph );
		$self->_add_patterns( $pat );
	} else {
		my $pat	= RDF::Query::Algebra::Load->new( $iri );
		$self->_add_patterns( $pat );
	}
	$self->{build}{method}		= 'LOAD';
}

sub _ClearGraphUpdate {
	my $self	= shift;
	$self->_eat(qr/CLEAR GRAPH/i);
	$self->_ws;
	if ($self->_test(qr/DEFAULT/i)) {
		$self->_eat(qr/DEFAULT/i);
		my $pat	= RDF::Query::Algebra::Clear->new();
		$self->_add_patterns( $pat );
	} else {
		$self->_IRIref;
		my ($graph)	= splice( @{ $self->{stack} } );
		my $pat	= RDF::Query::Algebra::Clear->new( $graph );
		$self->_add_patterns( $pat );
	}
	$self->{build}{method}		= 'CLEAR';
}

sub _CreateGraph {
	my $self	= shift;
	my $op		= $self->_eat(qr/CREATE\s+(SILENT\s+)?GRAPH/i);
	my $silent	= ($op =~ /SILENT/i);
	$self->_ws;
	$self->_IRIref;
	my ($graph)	= splice( @{ $self->{stack} } );
	my $pat	= RDF::Query::Algebra::Create->new( $graph );
	$self->_add_patterns( $pat );
	$self->{build}{method}		= 'CREATE';
}

sub _DropGraph {
	my $self	= shift;
	my $op		= $self->_eat(qr/DROP\s+(SILENT\s+)?GRAPH/i);
	my $silent	= ($op =~ /SILENT/i);
	$self->_ws;
	$self->_IRIref;
	my ($graph)	= splice( @{ $self->{stack} } );
	my $pat	= RDF::Query::Algebra::Clear->new( $graph );
	$self->_add_patterns( $pat );
	$self->{build}{method}		= 'CLEAR';
}

# [5] SelectQuery ::= 'SELECT' ( 'DISTINCT' | 'REDUCED' )? ( Var+ | '*' ) DatasetClause* WhereClause SolutionModifier
sub _SelectQuery {
	my $self	= shift;
	$self->_eat(qr/SELECT/i);
	$self->__consume_ws;
	
	if ($self->{tokens} =~ m/^(DISTINCT|REDUCED)/i) {
		my $mod	= $self->_eat( qr/DISTINCT|REDUCED/i );
		$self->__consume_ws;
		$self->{build}{options}{lc($mod)}	= 1;
	}
	
	my $star	= $self->__SelectVars;
	
	$self->_DatasetClause();
	
	$self->__consume_ws_opt;
	$self->_WhereClause;

	if ($star) {
		my $triples	= $self->{build}{triples} || [];
		my @vars;
		foreach my $t (@$triples) {
			my @v	= $t->binding_variables;
			push(@vars, @v);
		}
		@vars	= RDF::Query::_uniq( @vars );
		$self->{build}{variables}	= [ map { $self->new_variable($_) } @vars ];
	}

	$self->__consume_ws_opt;
	$self->_SolutionModifier();
	
	$self->__consume_ws_opt;
	if ($self->_test( qr/BINDINGS/i )) {
		$self->_eat( qr/BINDINGS/i );
		
		my @vars;
		$self->__consume_ws_opt;
		$self->_Var;
		push( @vars, splice(@{ $self->{stack} }));
		$self->__consume_ws_opt;
		while ($self->_test(qr/[\$?]/)) {
			$self->_Var;
			push( @vars, splice(@{ $self->{stack} }));
			$self->__consume_ws_opt;
		}
		
		$self->_eat('{');
		$self->__consume_ws_opt;
		while ($self->_Binding_test) {
			$self->_Binding;
			$self->__consume_ws_opt;
		}
		$self->_eat('}');
		$self->__consume_ws_opt;
		$self->{build}{bindings}{vars}	= \@vars;
	}
	
	$self->__solution_modifiers( $star );
	
	delete $self->{build}{options};
	$self->{build}{method}		= 'SELECT';
}

sub __SelectVars {
	my $self	= shift;
	my $star	= 0;
	if ($self->_test('*')) {
		$self->_eat('*');
		$star	= 1;
		$self->__consume_ws_opt;
	} else {
		my @vars;
		$self->__SelectVar;
		push( @vars, splice(@{ $self->{stack} }));
		$self->__consume_ws_opt;
		while ($self->__SelectVar_test) {
			$self->__SelectVar;
			push( @vars, splice(@{ $self->{stack} }));
			$self->__consume_ws_opt;
		}
		$self->{build}{variables}	= \@vars;
	}
	return $star;
}

sub _BrackettedAliasExpression {
	my $self	= shift;
	$self->_eat('(');
	$self->__consume_ws_opt;
	$self->_Expression;
	my ($expr)	= splice(@{ $self->{stack} });
	$self->__consume_ws_opt;
	$self->_eat('AS');
	$self->__consume_ws_opt;
	$self->_Var;
	my ($var)	= splice(@{ $self->{stack} });
	$self->__consume_ws_opt;
	$self->_eat(')');
	
	my $alias	= $self->new_alias_expression( $var, $expr );
	$self->_add_stack( $alias );
}

sub __SelectVar_test {
	my $self	= shift;
	local($self->{__aggregate_call_ok})	= 1;
#	return 1 if $self->_BuiltInCall_test;
	return 1 if $self->_test( qr/[(]/i);
	return $self->{tokens} =~ m'^[?$]';
}

sub __SelectVar {
	my $self	= shift;
	local($self->{__aggregate_call_ok})	= 1;
	if ($self->_test('(')) {
		$self->_BrackettedAliasExpression;
# 	} elsif ($self->_BuiltInCall_test) {
# 		$self->_BuiltInCall;
	} else {
		$self->_Var;
	}
}

# [6] ConstructQuery ::= 'CONSTRUCT' ConstructTemplate DatasetClause* WhereClause SolutionModifier
sub _ConstructQuery {
	my $self	= shift;
	$self->_eat(qr/CONSTRUCT/i);
	$self->__consume_ws_opt;
	$self->_ConstructTemplate;
	$self->__consume_ws_opt;
	$self->_DatasetClause();
	$self->__consume_ws_opt;
	$self->_WhereClause;
	$self->_SolutionModifier();
	
	my $pattern		= $self->{build}{triples}[0];
	my $triples		= delete $self->{build}{construct_triples};
	my $construct	= RDF::Query::Algebra::Construct->new( $pattern, $triples );
	$self->{build}{triples}[0]	= $construct;
	$self->{build}{method}		= 'CONSTRUCT';
}

# [7] DescribeQuery ::= 'DESCRIBE' ( VarOrIRIref+ | '*' ) DatasetClause* WhereClause? SolutionModifier
sub _DescribeQuery {
	my $self	= shift;
	$self->_eat(qr/DESCRIBE/i);
	$self->_ws;
	
	if ($self->_test('*')) {
		$self->_eat('*');
		$self->{build}{variables}	= ['*'];
		$self->__consume_ws_opt;
	} else {
		$self->_VarOrIRIref;
		$self->__consume_ws_opt;
		while ($self->_VarOrIRIref_test) {
			$self->_VarOrIRIref;
			$self->__consume_ws_opt;
		}
		$self->{build}{variables}	= [ splice(@{ $self->{stack} }) ];
	}
	
	$self->_DatasetClause();
	
	$self->__consume_ws_opt;
	if ($self->_WhereClause_test) {
		$self->_WhereClause;
	}
	
	$self->_SolutionModifier();
	$self->{build}{method}		= 'DESCRIBE';
}

# [8] AskQuery ::= 'ASK' DatasetClause* WhereClause
sub _AskQuery {
	my $self	= shift;
	$self->_eat(qr/ASK/i);
	$self->_ws;
	
	$self->_DatasetClause();
	
	$self->__consume_ws_opt;
	$self->_WhereClause;
	
	$self->{build}{variables}	= [];
	$self->{build}{method}		= 'ASK';
}

# [9] DatasetClause ::= 'FROM' ( DefaultGraphClause | NamedGraphClause )
sub _DatasetClause {
	my $self	= shift;
	
# 	my @dataset;
 	$self->{build}{sources}	= [];
	while ($self->_test( qr/FROM/i )) {
		$self->_eat( qr/FROM/i );
		$self->__consume_ws;
		if ($self->_test( qr/NAMED/i )) {
			$self->_NamedGraphClause;
		} else {
			$self->_DefaultGraphClause;
		}
		$self->__consume_ws_opt;
	}
}

# [10] DefaultGraphClause ::= SourceSelector
sub _DefaultGraphClause {
	my $self	= shift;
	$self->_SourceSelector;
	my ($source)	= splice(@{ $self->{stack} });
	push( @{ $self->{build}{sources} }, [$source] );
}

# [11] NamedGraphClause ::= 'NAMED' SourceSelector
sub _NamedGraphClause {
	my $self	= shift;
	$self->_eat( qr/NAMED/i );
	$self->__consume_ws_opt;
	$self->_SourceSelector;
	my ($source)	= splice(@{ $self->{stack} });
	push( @{ $self->{build}{sources} }, [$source, 'NAMED'] );
}

# [12] SourceSelector ::= IRIref
sub _SourceSelector {
	my $self	= shift;
	$self->_IRIref;
}

# [13] WhereClause ::= 'WHERE'? GroupGraphPattern
sub _WhereClause_test {
	my $self	= shift;
	return $self->_test( qr/WHERE|{/i );
}
sub _WhereClause {
	my $self	= shift;
	if ($self->_test( qr/WHERE/i )) {
		$self->_eat( qr/WHERE/i );
	}
	$self->__consume_ws_opt;
	$self->_GroupGraphPattern;
	
	my $ggp	= $self->_peek_pattern;
	$ggp->check_duplicate_blanks;
}

sub _Binding_test {
	my $self	= shift;
	return $self->_test( '(' );
}

sub _Binding {
	my $self	= shift;
	$self->_eat( '(' );
	$self->__consume_ws_opt;
	
	my @terms;
	$self->__consume_ws_opt;
	$self->_BindingValue;
	push( @terms, splice(@{ $self->{stack} }));
	$self->__consume_ws_opt;
	while ($self->_BindingValue_test) {
		$self->_BindingValue;
		push( @terms, splice(@{ $self->{stack} }));
		$self->__consume_ws_opt;
	}
	push( @{ $self->{build}{bindings}{terms} }, \@terms );
	$self->__consume_ws_opt;
	$self->_eat( ')' );
}

sub _BindingValue_test {
	my $self	= shift;
	return 1 if ($self->_test(qr/UNDEF|[<'".0-9]|(true|false)\b|_:|\([\n\r\t ]*\)/));
	return 0;
}

sub _BindingValue {
	my $self	= shift;
	if ($self->_test(qr/UNDEF/i)) {
		$self->_eat(qr/UNDEF/i);
		push(@{ $self->{stack} }, undef);
	} else {
		$self->_GraphTerm;
	}
}

# [20]  	GroupCondition	  ::=  	( BuiltInCall | FunctionCall | '(' Expression ( 'AS' Var )? ')' | Var )
sub __GroupByVar_test {
	my $self	= shift;
	return 1 if ($self->_BuiltInCall_test);
	return 1 if ($self->_IRIref_test);
	return 1 if ($self->_test( qr/[(]/i ));
	return 1 if ($self->_test(qr/[\$?]/));
}

sub __GroupByVar {
	my $self	= shift;
	if ($self->_test('(')) {
		$self->_eat('(');
		$self->__consume_ws_opt;
		$self->_Expression;
		my ($expr)	= splice(@{ $self->{stack} });
		$self->__consume_ws_opt;
		
		if ($self->_test(qr/AS/i)) {
			$self->_eat('AS');
			$self->__consume_ws_opt;
			$self->_Var;
			my ($var)	= splice(@{ $self->{stack} });
			$self->__consume_ws_opt;
			my $alias	= $self->new_alias_expression( $var, $expr );
			$self->_add_stack( $alias );
		} else {
			$self->_add_stack( $expr );
		}
		$self->_eat(')');
		
	} elsif ($self->_IRIref_test) {
		$$self->_FunctionCall;
	} elsif ($self->_BuiltInCall_test) {
		$self->_BuiltInCall;
	} else {
		$self->_Var;
	}
}

# [14] SolutionModifier ::= OrderClause? LimitOffsetClauses?
sub _SolutionModifier {
	my $self	= shift;
	
	if ($self->_test( qr/GROUP\s+BY/i )) {
		$self->_GroupClause;
		$self->__consume_ws_opt;
	}
	
	if ($self->_test( qr/HAVING/i )) {
		$self->_HavingClause;
		$self->__consume_ws_opt;
	}
	
	if ($self->_OrderClause_test) {
		$self->_OrderClause;
		$self->__consume_ws_opt;
	}
	
	if ($self->_LimitOffsetClauses_test) {
		$self->_LimitOffsetClauses;
	}
}

sub _GroupClause {
	my $self	= shift;
	$self->_eat( qr/GROUP\s+BY/i );
	
	my @vars;
	$self->__consume_ws_opt;
	$self->__GroupByVar;
	push( @vars, splice(@{ $self->{stack} }));
	$self->__consume_ws_opt;
	while ($self->__GroupByVar_test) {
		$self->__GroupByVar;
		push( @vars, splice(@{ $self->{stack} }));
		$self->__consume_ws_opt;
	}
	$self->{build}{__group_by}	= \@vars;
	$self->__consume_ws_opt;
}

sub _HavingClause {
	my $self	= shift;
	$self->_eat(qr/HAVING/i);
	$self->__consume_ws_opt;
	local($self->{__aggregate_call_ok})	= 1;
	$self->_Constraint;
	my ($expr) = splice(@{ $self->{stack} });
	$self->{build}{__having}	= $expr;
}

# [15] LimitOffsetClauses ::= ( LimitClause OffsetClause? | OffsetClause LimitClause? )
sub _LimitOffsetClauses_test {
	my $self	= shift;
	return $self->_test( qr/LIMIT|OFFSET/i );
}

sub _LimitOffsetClauses {
	my $self	= shift;
	if ($self->_LimitClause_test) {
		$self->_LimitClause;
		$self->__consume_ws_opt;
		if ($self->_OffsetClause_test) {
			$self->_OffsetClause;
		}
	} else {
		$self->_OffsetClause;
		$self->__consume_ws_opt;
		if ($self->_LimitClause_test) {
			$self->_LimitClause;
		}
	}
}

# [16] OrderClause ::= 'ORDER' 'BY' OrderCondition+
sub _OrderClause_test {
	my $self	= shift;
	return $self->_test( qr/ORDER[\n\r\t ]+BY/i );
}

sub _OrderClause {
	my $self	= shift;
	$self->_eat( qr/ORDER/i );
	$self->__consume_ws;
	$self->_eat( qr/BY/i );
	$self->__consume_ws_opt;
	my @order;
	$self->_OrderCondition;
	$self->__consume_ws_opt;
	push(@order, splice(@{ $self->{stack} }));
	while ($self->_OrderCondition_test) {
		$self->_OrderCondition;
		$self->__consume_ws_opt;
		push(@order, splice(@{ $self->{stack} }));
	}
	$self->{build}{options}{orderby}	= \@order;
}

# [17] OrderCondition ::= ( ( 'ASC' | 'DESC' ) BrackettedExpression ) | ( Constraint | Var )
sub _OrderCondition_test {
	my $self	= shift;
	return 1 if $self->_test( qr/ASC|DESC|[?\$]/i );
	return 1 if $self->_Constraint_test;
	return 0;
}

sub _OrderCondition {
	my $self	= shift;
	my $dir	= 'ASC';
	if ($self->_test( qr/ASC|DESC/i )) {
		$dir	= uc( $self->_eat( qr/ASC|DESC/i ) );
		$self->__consume_ws_opt;
		$self->_BrackettedExpression;
	} elsif ($self->_test( qr/[?\$]/ )) {
		$self->_Var;
	} else {
		$self->_Constraint;
	}
	my ($expr)	= splice(@{ $self->{stack} });
	$self->_add_stack( [ $dir, $expr ] );
}

# [18] LimitClause ::= 'LIMIT' INTEGER
sub _LimitClause_test {
	my $self	= shift;
	return $self->_test( qr/LIMIT/i );
}

sub _LimitClause {
	my $self	= shift;
	$self->_eat( qr/LIMIT/i );
	$self->__consume_ws;
	my $limit	= $self->_eat( $r_INTEGER );
	$self->{build}{options}{limit}	= $limit;
}

# [19] OffsetClause ::= 'OFFSET' INTEGER
sub _OffsetClause_test {
	my $self	= shift;
	return $self->_test( qr/OFFSET/i );
}

sub _OffsetClause {
	my $self	= shift;
	$self->_eat( qr/OFFSET/i );
	$self->__consume_ws;
	my $off	= $self->_eat( $r_INTEGER );
	$self->{build}{options}{offset}	= $off;
}

# [20] GroupGraphPattern ::= '{' TriplesBlock? ( ( GraphPatternNotTriples | Filter ) '.'? TriplesBlock? )* '}'
sub _GroupGraphPattern {
	my $self	= shift;
	
	$self->_eat('{');
	$self->__consume_ws_opt;
	
	if ($self->_SubSelect_test) {
		$self->_SubSelect;
	} else {
		$self->_GroupGraphPatternSub;
	}

	$self->__consume_ws_opt;
	$self->_eat('}');
}

sub _GroupGraphPatternSub {
	my $self	= shift;
	$self->_push_pattern_container;
	
	my $got_pattern	= 0;
	my $need_dot	= 0;
	if ($self->_TriplesBlock_test) {
		$need_dot	= 1;
		$got_pattern++;
		$self->_TriplesBlock;
		$self->__consume_ws_opt;
	}
	
	my $pos	= length($self->{tokens});
	while (not $self->_test('}')) {
		if ($self->_GraphPatternNotTriples_test) {
			$need_dot	= 0;
			$got_pattern++;
			$self->_GraphPatternNotTriples;
			$self->__consume_ws_opt;
			my ($data)	= splice(@{ $self->{stack} });
			$self->__handle_GraphPatternNotTriples( $data );
			$self->__consume_ws_opt;
		} elsif ($self->_test( qr/FILTER/i )) {
			$got_pattern++;
			$need_dot	= 0;
			$self->_Filter;
			$self->__consume_ws_opt;
		}
		
		if ($need_dot or $self->_test('.')) {
			$self->_eat('.');
			if ($got_pattern) {
				$need_dot		= 0;
				$got_pattern	= 0;
			} else {
				throw RDF::Query::Error::ParseError -text => "Syntax error: Extra dot found without preceding pattern";
			}
			$self->__consume_ws_opt;
		}
		
		if ($self->_TriplesBlock_test) {
			my $peek	= $self->_peek_pattern;
			if (blessed($peek) and $peek->isa('RDF::Query::Algebra::BasicGraphPattern')) {
				$self->_TriplesBlock;
				my $rhs		= $self->_remove_pattern;
				my $lhs		= $self->_remove_pattern;
				my $merged	= $self->__new_bgp( map { $_->triples } ($lhs, $rhs) );
				$self->_add_patterns( $merged );
			} else {
				$self->_TriplesBlock;
			}
			$self->__consume_ws_opt;
		}
		
		$self->__consume_ws_opt;
		last unless ($self->_test( qr/\S/ ));
		
		my $new	= length($self->{tokens});
		if ($pos == $new) {
			# we haven't progressed, and so would infinite loop if we don't break out and throw an error.
			$self->_syntax_error('');
		} else {
			$pos	= $new;
		}
	}
	
	my $cont		= $self->_pop_pattern_container;
	
	my @filters		= splice(@{ $self->{filters} });
	my @patterns;
	my $pattern	= RDF::Query::Algebra::GroupGraphPattern->new( @$cont );
	while (my $f = shift @filters) {
		$pattern	= RDF::Query::Algebra::Filter->new( $f, $pattern );
	}
	$self->_add_patterns( $pattern );
}

sub __handle_GraphPatternNotTriples {
	my $self	= shift;
	my $data	= shift;
	my ($class, @args)	= @$data;
	if ($class =~ /^RDF::Query::Algebra::(Optional|Minus)$/) {
		my $cont	= $self->_pop_pattern_container;
		my $ggp		= RDF::Query::Algebra::GroupGraphPattern->new( @$cont );
		$self->_push_pattern_container;
		# my $ggp	= $self->_remove_pattern();
		unless ($ggp) {
			$ggp	= RDF::Query::Algebra::GroupGraphPattern->new();
		}
		my $opt	= $class->new( $ggp, @args );
		$self->_add_patterns( $opt );
	} elsif ($class =~ /RDF::Query::Algebra::(Union|NamedGraph|GroupGraphPattern|Service)$/) {
		# no-op
	} else {
		throw RDF::Query::Error::ParseError 'Unrecognized GraphPattern: ' . $class;
	}
}

sub _SubSelect_test {
	my $self	= shift;
	return $self->_test(qr/SELECT/i);
}

sub _SubSelect {
	my $self	= shift;
	my $pattern;
	{
		local($self->{error});
		local($self->{namespaces})				= $self->{namespaces};
		local($self->{blank_ids})				= $self->{blank_ids};
		local($self->{stack})					= [];
		local($self->{filters})					= [];
		local($self->{pattern_container_stack})	= [];
		my $triples								= $self->_push_pattern_container();
		local($self->{build})					= {};
		$self->{build}{triples}					= $triples;
		if ($self->{baseURI}) {
			$self->{build}{base}	= $self->{baseURI};
		}
		
		$self->_eat(qr/SELECT/i);
		$self->__consume_ws;
		
		if ($self->{tokens} =~ m/^(DISTINCT|REDUCED)/i) {
			my $mod	= $self->_eat( qr/DISTINCT|REDUCED/i );
			$self->__consume_ws;
			$self->{build}{options}{lc($mod)}	= 1;
		}
		
		my $star	= $self->__SelectVars;
		
		$self->__consume_ws_opt;
		$self->_WhereClause;
		
		if ($star) {
			my $triples	= $self->{build}{triples} || [];
			my @vars;
			foreach my $t (@$triples) {
				my @v	= $t->binding_variables;
				push(@vars, @v);
			}
			@vars	= RDF::Query::_uniq( @vars );
			$self->{build}{variables}	= [ map { $self->new_variable($_) } @vars ];
		}
		
		$self->__consume_ws_opt;
		$self->_SolutionModifier();
		
		if ($self->{build}{options}{orderby}) {
			my $order	= delete $self->{build}{options}{orderby};
			my $pattern	= pop(@{ $self->{build}{triples} });
			my $sort	= RDF::Query::Algebra::Sort->new( $pattern, @$order );
			push(@{ $self->{build}{triples} }, $sort);
		}
		$self->__solution_modifiers( $star );
		
		delete $self->{build}{options};
		$self->{build}{method}		= 'SELECT';
		my $data	= delete $self->{build};
		my $query	= RDF::Query->_new(
			base			=> $self->{baseURI},
#			parser			=> $self,
			parsed			=> { %$data },
		);
		$pattern	= RDF::Query::Algebra::SubSelect->new( $query );
	}
	
	$self->_add_patterns( $pattern );
}

# [21] TriplesBlock ::= TriplesSameSubject ( '.' TriplesBlock? )?
sub _TriplesBlock_test {
	my $self	= shift;
	# VarOrTerm | TriplesNode -> (Var | GraphTerm) | (Collection | BlankNodePropertyList) -> Var | IRIref | RDFLiteral | NumericLiteral | BooleanLiteral | BlankNode | NIL | Collection | BlankNodePropertyList
	# but since a triple can't start with a literal, this is reduced to:
	# Var | IRIref | BlankNode | NIL
	return $self->_test(qr/[\$?]|<|_:|\[[\n\r\t ]*\]|\([\n\r\t ]*\)|\[|[[(]|${r_PNAME_NS}/);
}

sub _TriplesBlock {
	my $self	= shift;
	$self->_push_pattern_container;
	$self->__TriplesBlock;
	my $triples		= $self->_pop_pattern_container;
	my $bgp			= $self->__new_bgp( @$triples );
	$self->_add_patterns( $bgp );
}

## this one (with two underscores) doesn't pop patterns off the stack and make a BGP.
## instead, things are left on the stack so we can recurse without doing the wrong thing.
## the one with one underscore (_TriplesBlock) will pop everything off and make the BGP.
sub __TriplesBlock {
	my $self	= shift;
	$self->_TriplesSameSubjectPath;
	$self->__consume_ws_opt;
	my $got_dot	= 0;
	while ($self->_test('.')) {
		if ($got_dot) {
			throw RDF::Query::Error::ParseError -text => "Syntax error: found extra DOT after TriplesBlock";
		}
		$self->_eat('.');
		$got_dot++;
		$self->__consume_ws_opt;
		if ($self->_TriplesBlock_test) {
			$got_dot	= 0;
			$self->__TriplesBlock;
			$self->__consume_ws_opt;
		}
	}
}

# [22] GraphPatternNotTriples ::= OptionalGraphPattern | GroupOrUnionGraphPattern | GraphGraphPattern
sub _GraphPatternNotTriples_test {
	my $self	= shift;
	return $self->_test(qr/SERVICE|MINUS|OPTIONAL|{|GRAPH/i);
}

sub _GraphPatternNotTriples {
	my $self	= shift;
	if ($self->_test(qr/SERVICE/i)) {
		$self->_ServiceGraphPattern;
	} elsif ($self->_test(qr/MINUS/i)) {
		$self->_MinusGraphPattern;
	} elsif ($self->_OptionalGraphPattern_test) {
		$self->_OptionalGraphPattern;
	} elsif ($self->_GroupOrUnionGraphPattern_test) {
		$self->_GroupOrUnionGraphPattern;
	} else {
		$self->_GraphGraphPattern;
	}
}

sub _ServiceGraphPattern {
	my $self	= shift;
	$self->_eat( qr/SERVICE/i );
	$self->__consume_ws_opt;
	$self->_IRIref;
	my ($iri)	= splice( @{ $self->{stack} } );
	$self->__consume_ws_opt;
	$self->_GroupGraphPattern;
	my $ggp	= $self->_remove_pattern;
	
	my $pattern	= RDF::Query::Algebra::Service->new( $iri, $ggp );
	$self->_add_patterns( $pattern );
	
	my $opt		= ['RDF::Query::Algebra::Service', $iri, $ggp];
	$self->_add_stack( $opt );
}

# [23] OptionalGraphPattern ::= 'OPTIONAL' GroupGraphPattern
sub _OptionalGraphPattern_test {
	my $self	= shift;
	return $self->_test( qr/OPTIONAL/i );
}

sub _OptionalGraphPattern {
	my $self	= shift;
	$self->_eat( qr/OPTIONAL/i );
	$self->__consume_ws_opt;
	$self->_GroupGraphPattern;
	my $ggp	= $self->_remove_pattern;
	my $opt		= ['RDF::Query::Algebra::Optional', $ggp];
	$self->_add_stack( $opt );
}

sub _MinusGraphPattern {
	my $self	= shift;
	$self->_eat( qr/MINUS/i );
	$self->__consume_ws_opt;
	$self->_GroupGraphPattern;
	my $ggp	= $self->_remove_pattern;
	my $opt		= ['RDF::Query::Algebra::Minus', $ggp];
	$self->_add_stack( $opt );
}

# [24] GraphGraphPattern ::= 'GRAPH' VarOrIRIref GroupGraphPattern
sub _GraphGraphPattern {
	my $self	= shift;
	$self->_eat( qr/GRAPH/i );
	$self->__consume_ws;
	$self->_VarOrIRIref;
	my ($graph)	= splice(@{ $self->{stack} });
	$self->__consume_ws_opt;
	
# 	if ($graph->isa('RDF::Trine::Node::Resource')) {
		local($self->{named_graph})	= $graph;
		$self->_GroupGraphPattern;
# 	} else {
# 		$self->_GroupGraphPattern;
# 	}
	
	my $ggp	= $self->_remove_pattern;
	my $pattern	= RDF::Query::Algebra::NamedGraph->new( $graph, $ggp );
	$self->_add_patterns( $pattern );
	$self->_add_stack( [ 'RDF::Query::Algebra::NamedGraph' ] );
}

# [25] GroupOrUnionGraphPattern ::= GroupGraphPattern ( 'UNION' GroupGraphPattern )*
sub _GroupOrUnionGraphPattern_test {
	my $self	= shift;
	return $self->_test('{');
}

sub _GroupOrUnionGraphPattern {
	my $self	= shift;
	$self->_GroupGraphPattern;
	my $ggp	= $self->_remove_pattern;
	$self->__consume_ws_opt;
	
	if ($self->_test( qr/UNION/i )) {
		while ($self->_test( qr/UNION/i )) {
			$self->_eat( qr/UNION/i );
			$self->__consume_ws_opt;
			$self->_GroupGraphPattern;
			$self->__consume_ws_opt;
			my $rhs	= $self->_remove_pattern;
			$ggp	= RDF::Query::Algebra::Union->new( $ggp, $rhs );
		}
		$self->_add_patterns( $ggp );
		$self->_add_stack( [ 'RDF::Query::Algebra::Union' ] );
	} else {
		$self->_add_patterns( $ggp );
		$self->_add_stack( [ 'RDF::Query::Algebra::GroupGraphPattern' ] );
	}
}

# [26] Filter ::= 'FILTER' Constraint
sub _Filter {
	my $self	= shift;
	$self->_eat( qr/FILTER/i );
	$self->__consume_ws_opt;
	$self->_Constraint;
	my ($expr) = splice(@{ $self->{stack} });
	$self->_add_filter( $expr );
}

# [27] Constraint ::= BrackettedExpression | BuiltInCall | FunctionCall
sub _Constraint_test {
	my $self	= shift;
	return 1 if $self->_test( qr/[(]/ );
	return 1 if $self->_BuiltInCall_test;
	return 1 if $self->_FunctionCall_test;
	return 0;
}

sub _Constraint {
	my $self	= shift;
	if ($self->_BrackettedExpression_test) {
		$self->_BrackettedExpression();
	} elsif ($self->_BuiltInCall_test) {
		$self->_BuiltInCall();
	} else {
		$self->_FunctionCall();
	}
}

# [28] FunctionCall ::= IRIref ArgList
sub _FunctionCall_test {
	my $self	= shift;
	return $self->_IRIref_test;
}

sub _FunctionCall {
	my $self	= shift;
	$self->_IRIref;
	my ($iri)	= splice(@{ $self->{stack} });
	
	$self->__consume_ws_opt;
	
	$self->_ArgList;
	my @args	= splice(@{ $self->{stack} });
	my $func	= $self->new_function_expression( $iri, @args );
	$self->_add_stack( $func );
}

# [29] ArgList ::= ( NIL | '(' Expression ( ',' Expression )* ')' )
sub _ArgList_test {
	my $self	= shift;
	return $self->_test('(');
}

sub _ArgList {
	my $self	= shift;
	$self->_eat('(');
	$self->__consume_ws_opt;
	my @args;
	unless ($self->_test(')')) {
		$self->_Expression;
		push( @args, splice(@{ $self->{stack} }) );
		while ($self->_test(',')) {
			$self->_eat(',');
			$self->__consume_ws_opt;
			$self->_Expression;
			push( @args, splice(@{ $self->{stack} }) );
		}
	}
	$self->_eat(')');
	$self->_add_stack( @args );
}

# [30] ConstructTemplate ::= '{' ConstructTriples? '}'
sub _ConstructTemplate {
	my $self	= shift;
	$self->_push_pattern_container;
	$self->_eat( '{' );
	$self->__consume_ws_opt;
	
	if ($self->_ConstructTriples_test) {
		$self->_ConstructTriples;
	}

	$self->__consume_ws_opt;
	$self->_eat( '}' );
	my $cont	= $self->_pop_pattern_container;
	$self->{build}{construct_triples}	= $cont;
}

# [31] ConstructTriples ::= TriplesSameSubject ( '.' ConstructTriples? )?
sub _ConstructTriples_test {
	my $self	= shift;
	return $self->_TriplesBlock_test;
}

sub _ConstructTriples {
	my $self	= shift;
	$self->_TriplesSameSubject;
	$self->__consume_ws_opt;
	while ($self->_test(qr/[.]/)) {
		$self->_eat( qr/[.]/ );
		$self->__consume_ws_opt;
		if ($self->_ConstructTriples_test) {
			$self->_TriplesSameSubject;
		}
	}
}

# [32] TriplesSameSubject ::= VarOrTerm PropertyListNotEmpty | TriplesNode PropertyList
sub _TriplesSameSubject {
	my $self	= shift;
	my @triples;
	if ($self->_TriplesNode_test) {
		$self->_TriplesNode;
		my ($s)	= splice(@{ $self->{stack} });
		$self->__consume_ws_opt;
		$self->_PropertyList;
		$self->__consume_ws_opt;
		
		my @list	= splice(@{ $self->{stack} });
		foreach my $data (@list) {
			push(@triples, $self->__new_statement( $s, @$data ));
		}
	} else {
		$self->_VarOrTerm;
		my ($s)	= splice(@{ $self->{stack} });

		$self->__consume_ws_opt;
		$self->_PropertyListNotEmpty;
		$self->__consume_ws_opt;
		my (@list)	= splice(@{ $self->{stack} });
		foreach my $data (@list) {
			push(@triples, $self->__new_statement( $s, @$data ));
		}
	}
	
	$self->_add_patterns( @triples );
#	return @triples;
}

# TriplesSameSubjectPath ::= VarOrTerm PropertyListNotEmptyPath | TriplesNode PropertyListPath
sub _TriplesSameSubjectPath {
	my $self	= shift;
	my @triples;
	if ($self->_TriplesNode_test) {
		$self->_TriplesNode;
		my ($s)	= splice(@{ $self->{stack} });
		$self->__consume_ws_opt;
		$self->_PropertyListPath;
		$self->__consume_ws_opt;
		
		my @list	= splice(@{ $self->{stack} });
		foreach my $data (@list) {
			push(@triples, $self->__new_statement( $s, @$data ));
		}
	} else {
		$self->_VarOrTerm;
		my ($s)	= splice(@{ $self->{stack} });

		$self->__consume_ws_opt;
		$self->_PropertyListNotEmptyPath;
		$self->__consume_ws_opt;
		my (@list)	= splice(@{ $self->{stack} });
		foreach my $data (@list) {
			push(@triples, $self->__new_statement( $s, @$data ));
		}
	}
	
	$self->_add_patterns( @triples );
#	return @triples;
}

# [33] PropertyListNotEmpty ::= Verb ObjectList ( ';' ( Verb ObjectList )? )*
sub _PropertyListNotEmpty {
	my $self	= shift;
	$self->_Verb;
	my ($v)	= splice(@{ $self->{stack} });
	$self->__consume_ws_opt;
	$self->_ObjectList;
	my @l	= splice(@{ $self->{stack} });
	my @props		= map { [$v, $_] } @l;
	while ($self->_test(qr'\s*;')) {
		$self->_eat(';');
		$self->__consume_ws_opt;
		if ($self->_Verb_test) {
			$self->_Verb;
			my ($v)	= splice(@{ $self->{stack} });
			$self->__consume_ws_opt;
			$self->_ObjectList;
			my @l	= splice(@{ $self->{stack} });
			push(@props, map { [$v, $_] } @l);
		}
	}
	$self->_add_stack( @props );
}

# [34] PropertyList ::= PropertyListNotEmpty?
sub _PropertyList {
	my $self	= shift;
	if ($self->_Verb_test) {
		$self->_PropertyListNotEmpty;
	}
}

# [33] PropertyListNotEmptyPath ::= (VerbPath | VerbSimple) ObjectList ( ';' ( (VerbPath | VerbSimple) ObjectList )? )*
sub _PropertyListNotEmptyPath {
	my $self	= shift;
	if ($self->_VerbPath_test) {
		$self->_VerbPath;
	} else {
		$self->_VerbSimple;
	}
	my ($v)	= splice(@{ $self->{stack} });
	$self->__consume_ws_opt;
	$self->_ObjectList;
	my @l	= splice(@{ $self->{stack} });
	my @props		= map { [$v, $_] } @l;
	while ($self->_test(qr'\s*;')) {
		$self->_eat(';');
		$self->__consume_ws_opt;
		if ($self->_VerbPath_test or $self->_VerbSimple_test) {
			if ($self->_VerbPath_test) {
				$self->_VerbPath;
			} else {
				$self->_VerbSimple;
			}
			my ($v)	= splice(@{ $self->{stack} });
			$self->__consume_ws_opt;
			$self->_ObjectList;
			my @l	= splice(@{ $self->{stack} });
			push(@props, map { [$v, $_] } @l);
		}
	}
	$self->_add_stack( @props );
}

# [34] PropertyListPath ::= PropertyListNotEmptyPath?
sub _PropertyListPath {
	my $self	= shift;
	if ($self->_Verb_test) {
		$self->_PropertyListNotEmptyPath;
	}
}

# [35] ObjectList ::= Object ( ',' Object )*
sub _ObjectList {
	my $self	= shift;
	
	my @list;
	$self->_Object;
	push(@list, splice(@{ $self->{stack} }));
	
	$self->__consume_ws_opt;
	while ($self->_test(',')) {
		$self->_eat(',');
		$self->__consume_ws_opt;
		$self->_Object;
		push(@list, splice(@{ $self->{stack} }));
		$self->__consume_ws_opt;
	}
	$self->_add_stack( @list );
}

# [36] Object ::= GraphNode
sub _Object {
	my $self	= shift;
	$self->_GraphNode;
}

# [37] Verb ::= VarOrIRIref | 'a'
sub _Verb_test {
	my $self	= shift;
	return $self->_test( qr/a[\n\t\r <]|[?\$]|<|${r_PNAME_LN}|${r_PNAME_NS}/ );
}

sub _Verb {
	my $self	= shift;
	if ($self->_test(qr/a[\n\t\r <]/)) {
		$self->_eat('a');
		$self->__consume_ws;
		my $type	= RDF::Query::Node::Resource->new( $rdf->type->uri_value );
		$self->_add_stack( $type );
	} else {
		$self->_VarOrIRIref;
	}
}

# VerbSimple ::= Var
sub _VerbSimple_test {
	my $self	= shift;
	return 1 if ($self->_test(qr/[\$?]/));
}

sub _VerbSimple {
	my $self	= shift;
	$self->_Var;
}

# VerbPath ::= Path
sub _VerbPath_test {
	my $self	= shift;
	return 1 if ($self->_IRIref_test);
	return 1 if ($self->_test(qr/\^|[(a!]/));
}

sub _VerbPath {
	my $self	= shift;
	$self->_Path
}

# [74]  	Path	  ::=  	PathAlternative
sub _Path {
	my $self	= shift;
	$self->_PathAlternative;
}

################################################################################

# [75]  	PathAlternative	  ::=  	PathSequence ( '|' PathSequence )*
sub _PathAlternative {
	my $self	= shift;
	$self->_PathSequence;
	$self->__consume_ws_opt;
	while ($self->_test(qr/[|]/)) {
		my ($lhs)	= splice(@{ $self->{stack} });
		$self->_eat(qr/[|]/);
		$self->__consume_ws_opt;
		$self->_PathOneInPropertyClass;
		$self->__consume_ws_opt;
		my ($rhs)	= splice(@{ $self->{stack} });
		$self->_add_stack( ['PATH', '|', $lhs, $rhs] );
	}
}

# [76]  	PathSequence	  ::=  	PathEltOrInverse ( '/' PathEltOrInverse | '^' PathElt )*
sub _PathSequence {
	my $self	= shift;
	$self->_PathEltOrInverse;
	$self->__consume_ws_opt;
	while ($self->_test(qr<[/^]>)) {
		my $op;
		my ($lhs)	= splice(@{ $self->{stack} });
		if ($self->_test(qr</>)) {
			$op	= $self->_eat(qr</>);
			$self->__consume_ws_opt;
			$self->_PathEltOrInverse;
		} else {
			$op	= $self->_eat(qr<\^>);
			$self->__consume_ws_opt;
			$self->_PathElt;
		}
		my ($rhs)	= splice(@{ $self->{stack} });
		$self->_add_stack( ['PATH', $op, $lhs, $rhs] );
	}
}

# [77]  	PathElt	  ::=  	PathPrimary PathMod?
sub _PathElt {
	my $self	= shift;
	$self->_PathPrimary;
#	$self->__consume_ws_opt;
	if ($self->_PathMod_test) {
		my @path	= splice(@{ $self->{stack} });
		$self->_PathMod;
		my ($mod)	= splice(@{ $self->{stack} });
		if (defined($mod)) {
			$self->_add_stack( ['PATH', $mod, @path] );
		} else {
			# this might happen if we descend into _PathMod by mistaking a + as
			# a path modifier, but _PathMod figures out it's actually part of a
			# signed numeric object that follows the path
			$self->_add_stack( @path );
		}
	}
}

# [78]  	PathEltOrInverse	  ::=  	PathElt | '^' PathElt
sub _PathEltOrInverse {
	my $self	= shift;
	if ($self->_test(qr/\^/)) {
		$self->_eat(qr<\^>);
		$self->__consume_ws_opt;
		$self->_PathElt;
		my @props	= splice(@{ $self->{stack} });
		$self->_add_stack( [ 'PATH', '^', @props ] );
	} else {
		$self->_PathElt;
	}
}

# [79]  	PathMod	  ::=  	( '*' | '?' | '+' | '{' ( Integer ( ',' ( '}' | Integer '}' ) | '}' ) ) )
sub _PathMod_test {
	my $self	= shift;
	return 1 if ($self->_test(qr/[*?+{]/));
}

sub _PathMod {
	my $self	= shift;
	if ($self->_test(qr/[*?+]/)) {
		if ($self->_test(qr/[+][.0-9]/)) {
			return;
		} else {
			$self->_add_stack( $self->_eat(qr/[*?+]/) );
			$self->__consume_ws_opt;
		}
	} else {
		$self->_eat(qr/{/);
		$self->__consume_ws_opt;
		my $value	= $self->_eat( $r_INTEGER );
		$self->__consume_ws_opt;
		if ($self->_test(qr/,/)) {
			$self->_eat(qr/,/);
			$self->__consume_ws_opt;
			if ($self->_test(qr/}/)) {
				$self->_eat(qr/}/);
				$self->_add_stack( "$value-" );
			} else {
				my $end	= $self->_eat( $r_INTEGER );
				$self->__consume_ws_opt;
				$self->_eat(qr/}/);
				$self->_add_stack( "$value-$end" );
			}
		} else {
			$self->_eat(qr/}/);
			$self->_add_stack( "$value" );
		}
	}
}

# [80]  	PathPrimary	  ::=  	( IRIref | 'a' | '!' PathNegatedPropertyClass | '(' Path ')' )
sub _PathPrimary {
	my $self	= shift;
	if ($self->_IRIref_test) {
		$self->_IRIref;
	} elsif ($self->_test(qr/a[\n\t\r <]/)) {
		$self->_eat(qr/a/);
		my $type	= RDF::Query::Node::Resource->new( $rdf->type->uri_value );
		$self->_add_stack( $type );
	} elsif ($self->_test(qr/[!]/)) {
		$self->_eat(qr/[!]/);
		$self->__consume_ws_opt;
		$self->_PathNegatedPropertyClass;
		my (@path)	= splice(@{ $self->{stack} });
		$self->_add_stack( ['PATH', '!', @path] );
	} else {
		$self->_eat(qr/[(]/);
		$self->__consume_ws_opt;
		$self->_Path;
		$self->__consume_ws_opt;
		$self->_eat(qr/[)]/);
	}
}

# [81]  	PathNegatedPropertyClass	  ::=  	( PathOneInPropertyClass | '(' ( PathOneInPropertyClass ( '|' PathOneInPropertyClass )* )? ')' )
sub _PathNegatedPropertyClass {
	my $self	= shift;
	if ($self->_test(qr/[(]/)) {
		$self->_eat(qr/[(]/);
		$self->__consume_ws_opt;
		
		my @nodes;
		if ($self->_PathOneInPropertyClass_test) {
			$self->_PathOneInPropertyClass;
			push(@nodes, splice(@{ $self->{stack} }));
			$self->__consume_ws_opt;
			while ($self->_test(qr/[|]/)) {
				$self->_eat(qr/[|]/);
				$self->__consume_ws_opt;
				$self->_PathOneInPropertyClass;
				$self->__consume_ws_opt;
				push(@nodes, splice(@{ $self->{stack} }));
#				$self->_add_stack( ['PATH', '|', $lhs, $rhs] );
			}
		}
		$self->_eat(qr/[)]/);
		$self->_add_stack( @nodes );
	} else {
		$self->_PathOneInPropertyClass;
	}
}

# [82]  	PathOneInPropertyClass	  ::=  	IRIref | 'a'
sub _PathOneInPropertyClass_test {
	my $self	= shift;
	return 1 if $self->_IRIref_test;
	return 1 if ($self->_test(qr/a[|)\n\t\r <]/));
	return 1 if ($self->_test(qr/\^/));
	return 0;
}

sub _PathOneInPropertyClass {
	my $self	= shift;
	my $rev		= 0;
	if ($self->_test(qr/\^/)) {
		$self->_eat(qr/\^/);
		$rev	= 1;
	}
	if ($self->_test(qr/a[|)\n\t\r <]/)) {
		$self->_eat(qr/a/);
		my $type	= RDF::Query::Node::Resource->new( $rdf->type->uri_value );
		if ($rev) {
			$self->_add_stack( [ 'PATH', '^', $type ] );
		} else {
			$self->_add_stack( $type );
		}
	} else {
		$self->_IRIref;
		if ($rev) {
			my ($path)	= splice(@{ $self->{stack} });
			$self->_add_stack( [ 'PATH', '^', $path ] );
		}
	}
}

################################################################################

# [38] TriplesNode ::= Collection | BlankNodePropertyList
sub _TriplesNode_test {
	my $self	= shift;
	return $self->_test(qr/[[(](?![\n\r\t ]*\])(?![\n\r\t ]*\))/);
}

sub _TriplesNode {
	my $self	= shift;
	if ($self->_test(qr/\(/)) {
		$self->_Collection;
	} else {
		$self->_BlankNodePropertyList;
	}
}

# [39] BlankNodePropertyList ::= '[' PropertyListNotEmpty ']'
sub _BlankNodePropertyList {
	my $self	= shift;
	$self->_eat('[');
	$self->__consume_ws_opt;
#	$self->_PropertyListNotEmpty;
	$self->_PropertyListNotEmptyPath;
	$self->__consume_ws_opt;
	$self->_eat(']');
	
	my @props	= splice(@{ $self->{stack} });
	my $subj	= $self->new_blank;
	my @triples	= map { $self->__new_statement( $subj, @$_ ) } @props;
	$self->_add_patterns( @triples );
	$self->_add_stack( $subj );
}

# [40] Collection ::= '(' GraphNode+ ')'
sub _Collection {
	my $self	= shift;
	$self->_eat('(');
	$self->__consume_ws_opt;
	$self->_GraphNode;
	$self->__consume_ws_opt;
	
	my @nodes;
	push(@nodes, splice(@{ $self->{stack} }));
	
	while ($self->_GraphNode_test) {
		$self->_GraphNode;
		$self->__consume_ws_opt;
		push(@nodes, splice(@{ $self->{stack} }));
	}
	
	$self->_eat(')');
	
	my $subj	= $self->new_blank;
	my $cur		= $subj;
	my $last;

	my $first	= RDF::Query::Node::Resource->new( $rdf->first->uri_value );
	my $rest	= RDF::Query::Node::Resource->new( $rdf->rest->uri_value );
	my $nil		= RDF::Query::Node::Resource->new( $rdf->nil->uri_value );

	
	my @triples;
	foreach my $node (@nodes) {
		push(@triples, $self->__new_statement( $cur, $first, $node ) );
		my $new	= $self->new_blank;
		push(@triples, $self->__new_statement( $cur, $rest, $new ) );
		$last	= $cur;
		$cur	= $new;
	}
	pop(@triples);
	push(@triples, $self->__new_statement( $last, $rest, $nil ));
	$self->_add_patterns( @triples );
	
	$self->_add_stack( $subj );
}

# [41] GraphNode ::= VarOrTerm | TriplesNode
sub _GraphNode_test {
	my $self	= shift;
	# VarOrTerm | TriplesNode -> (Var | GraphTerm) | (Collection | BlankNodePropertyList) -> Var | IRIref | RDFLiteral | NumericLiteral | BooleanLiteral | BlankNode | NIL | Collection | BlankNodePropertyList
	# but since a triple can't start with a literal, this is reduced to:
	# Var | IRIref | BlankNode | NIL
	return $self->_test(qr/[\$?]|<|['"]|(true\b|false\b)|([+-]?\d)|_:|${r_ANON}|${r_NIL}|\[|[[(]/);
}

sub _GraphNode {
	my $self	= shift;
	if ($self->_TriplesNode_test) {
		$self->_TriplesNode;
	} else {
		$self->_VarOrTerm;
	}
}

# [42] VarOrTerm ::= Var | GraphTerm
sub _VarOrTerm_test {
	my $self	= shift;
	return 1 if ($self->_test(qr/[\$?]/));
	return 1 if ($self->_test(qr/[<'".0-9]|(true|false)\b|_:|\([\n\r\t ]*\)/));
	return 0;
}

sub _VarOrTerm {
	my $self	= shift;
	if ($self->{tokens} =~ m'^[?$]') {
		$self->_Var;
	} else {
		$self->_GraphTerm;
	}
}

# [43] VarOrIRIref ::= Var | IRIref
sub _VarOrIRIref_test {
	my $self	= shift;
	return $self->_test(qr/[\$?]|<|${r_PNAME_LN}|${r_PNAME_NS}/);
}

sub _VarOrIRIref {
	my $self	= shift;
	if ($self->{tokens} =~ m'^[?$]') {
		$self->_Var;
	} else {
		$self->_IRIref;
	}
}

# [44] Var ::= VAR1 | VAR2
sub _Var {
	my $self	= shift;
	my $var		= ($self->_test( $r_VAR1 )) ? $self->_eat( $r_VAR1 ) : $self->_eat( $r_VAR2 );
	$self->_add_stack( RDF::Query::Node::Variable->new( substr($var,1) ) );
}

# [45] GraphTerm ::= IRIref | RDFLiteral | NumericLiteral | BooleanLiteral | BlankNode | NIL
sub _GraphTerm {
	my $self	= shift;
	if ($self->_test(qr/(true|false)\b/)) {
		$self->_BooleanLiteral;
	} elsif ($self->_test('(')) {
		$self->_NIL;
	} elsif ($self->_test( $r_ANON ) or $self->_test('_:')) {
		$self->_BlankNode;
	} elsif ($self->_test(qr/[-+]?\d/)) {
		$self->_NumericLiteral;
	} elsif ($self->_test(qr/['"]/)) {
		$self->_RDFLiteral;
	} else {
		$self->_IRIref;
	}
}

# [46] Expression ::= ConditionalOrExpression
sub _Expression {
	my $self	= shift;
	$self->_ConditionalOrExpression;
}

# [47] ConditionalOrExpression ::= ConditionalAndExpression ( '||' ConditionalAndExpression )*
sub _ConditionalOrExpression {
	my $self	= shift;
	my @list;
	
	$self->_ConditionalAndExpression;
	push(@list, splice(@{ $self->{stack} }));
	
	$self->__consume_ws_opt;
	while ($self->_test('||')) {
		$self->_eat('||');
		$self->__consume_ws_opt;
		$self->_ConditionalAndExpression;
		push(@list, splice(@{ $self->{stack} }));
	}
	
	if (scalar(@list) > 1) {
		$self->_add_stack( $self->new_function_expression( 'sparql:logical-or', @list ) );
	} else {
		$self->_add_stack( @list );
	}
	Carp::confess $self->{tokens} if (scalar(@{ $self->{stack} }) == 0);
}

# [48] ConditionalAndExpression ::= ValueLogical ( '&&' ValueLogical )*
sub _ConditionalAndExpression {
	my $self	= shift;
	$self->_ValueLogical;
	my @list	= splice(@{ $self->{stack} });
	
	$self->__consume_ws_opt;
	while ($self->_test('&&')) {
		$self->_eat('&&');
		$self->__consume_ws_opt;
		$self->_ValueLogical;
		push(@list, splice(@{ $self->{stack} }));
	}
	
	if (scalar(@list) > 1) {
		$self->_add_stack( $self->new_function_expression( 'sparql:logical-and', @list ) );
	} else {
		$self->_add_stack( @list );
	}
}

# [49] ValueLogical ::= RelationalExpression
sub _ValueLogical {
	my $self	= shift;
	$self->_RelationalExpression;
}

# [50] RelationalExpression ::= NumericExpression ( '=' NumericExpression | '!=' NumericExpression | '<' NumericExpression | '>' NumericExpression | '<=' NumericExpression | '>=' NumericExpression )?
sub _RelationalExpression {
	my $self	= shift;
	$self->_NumericExpression;
	
	$self->__consume_ws_opt;
	if ($self->_test(qr/[!<>]?=|[<>]/)) {
		if ($self->_test( $r_IRI_REF )) {
			throw RDF::Query::Error::ParseError -text => "Syntax error: IRI found where expression expected";
		}
		my @list	= splice(@{ $self->{stack} });
		my $op	= $self->_eat(qr/[!<>]?=|[<>]/);
		$op		= '==' if ($op eq '=');
		$self->__consume_ws_opt;
		$self->_NumericExpression;
		push(@list, splice(@{ $self->{stack} }));
		$self->_add_stack( $self->new_binary_expression( $op, @list ) );
	} elsif ($self->_test(qr/(NOT )?IN/)) {
		my @list	= splice(@{ $self->{stack} });
		my $op		= lc($self->_eat(qr/(NOT )?IN/));
		$op			=~ s/\s+//g;
		$self->__consume_ws_opt;
		$self->_ExpressionList();
		push(@list, splice(@{ $self->{stack} }));
		$self->_add_stack( $self->new_function_expression( "sparql:$op", @list ) );
	}
}

sub _ExpressionList {
	my $self	= shift;
	$self->_eat('(');
	$self->__consume_ws_opt;
	my @args;
	unless ($self->_test(')')) {
		$self->_Expression;
		push( @args, splice(@{ $self->{stack} }) );
		while ($self->_test(',')) {
			$self->_eat(',');
			$self->__consume_ws_opt;
			$self->_Expression;
			push( @args, splice(@{ $self->{stack} }) );
		}
	}
	$self->_eat(')');
	$self->_add_stack( @args );
}

# [51] NumericExpression ::= AdditiveExpression
sub _NumericExpression {
	my $self	= shift;
	$self->_AdditiveExpression;
}

# [52] AdditiveExpression ::= MultiplicativeExpression ( '+' MultiplicativeExpression | '-' MultiplicativeExpression | NumericLiteralPositive | NumericLiteralNegative )*
sub _AdditiveExpression {
	my $self	= shift;
	$self->_MultiplicativeExpression;
	my ($expr)	= splice(@{ $self->{stack} });
	
	$self->__consume_ws_opt;
	while ($self->_test(qr/[-+]/)) {
		my $op	= $self->_eat(qr/[-+]/);
		$self->__consume_ws_opt;
		$self->_MultiplicativeExpression;
		my ($rhs)	= splice(@{ $self->{stack} });
		$expr	= $self->new_binary_expression( $op, $expr, $rhs );
	}
	$self->_add_stack( $expr );
}

# [53] MultiplicativeExpression ::= UnaryExpression ( '*' UnaryExpression | '/' UnaryExpression )*
sub _MultiplicativeExpression {
	my $self	= shift;
	$self->_UnaryExpression;
	my ($expr)	= splice(@{ $self->{stack} });
	
	$self->__consume_ws_opt;
	while ($self->_test(qr#[*/]#)) {
		my $op	= $self->_eat(qr#[*/]#);
		$self->__consume_ws_opt;
		$self->_UnaryExpression;
		my ($rhs)	= splice(@{ $self->{stack} });
		$expr	= $self->new_binary_expression( $op, $expr, $rhs );
	}
	$self->_add_stack( $expr );
}

# [54] UnaryExpression ::= '!' PrimaryExpression  | '+' PrimaryExpression  | '-' PrimaryExpression  | PrimaryExpression
sub _UnaryExpression {
	my $self	= shift;
	if ($self->_test('!')) {
		$self->_eat('!');
		$self->__consume_ws_opt;
		$self->_PrimaryExpression;
		my ($expr)	= splice(@{ $self->{stack} });
		my $not		= $self->new_unary_expression( '!', $expr );
		$self->_add_stack( $not );
	} elsif ($self->_test('+')) {
		$self->_eat('+');
		$self->__consume_ws_opt;
		$self->_PrimaryExpression;
		my ($expr)	= splice(@{ $self->{stack} });
		
		### if it's just a literal, force the positive down into the literal
		if (blessed($expr) and $expr->isa('RDF::Trine::Node::Literal') and $expr->is_numeric_type) {
			my $value	= '+' . $expr->literal_value;
			$expr->literal_value( $value );
			$self->_add_stack( $expr );
		} else {
			$self->_add_stack( $expr );
		}
	} elsif ($self->_test('-')) {
		$self->_eat('-');
		$self->__consume_ws_opt;
		$self->_PrimaryExpression;
		my ($expr)	= splice(@{ $self->{stack} });
		
		### if it's just a literal, force the negative down into the literal instead of make an unnecessary multiplication.
		if (blessed($expr) and $expr->isa('RDF::Trine::Node::Literal') and $expr->is_numeric_type) {
			my $value	= -1 * $expr->literal_value;
			$expr->literal_value( $value );
			$self->_add_stack( $expr );
		} else {
			my $int		= $xsd->integer->uri_value;
			my $neg		= $self->new_binary_expression( '*', $self->new_literal('-1', undef, $int), $expr );
			$self->_add_stack( $neg );
		}
	} else {
		$self->_PrimaryExpression;
	}
}

# [55] PrimaryExpression ::= BrackettedExpression | BuiltInCall | IRIrefOrFunction | RDFLiteral | NumericLiteral | BooleanLiteral | Var
sub _PrimaryExpression {
	my $self	= shift;
	if ($self->_BrackettedExpression_test) {
		$self->_BrackettedExpression;
	} elsif ($self->_BuiltInCall_test) {
		$self->_BuiltInCall;
	} elsif ($self->_IRIref_test) {
		$self->_IRIrefOrFunction;
	} elsif ($self->_test(qr/[\$?]/)) {
		$self->_Var;
	} elsif ($self->_test(qr/(true|false)\b/)) {
		$self->_BooleanLiteral;
	} elsif ($self->_test(qr/[-+]?\d/)) {
		$self->_NumericLiteral;
	} else {	# if ($self->_test(qr/['"]/)) {
		$self->_RDFLiteral;
	}
}

# [56] BrackettedExpression ::= '(' Expression ')'
sub _BrackettedExpression_test {
	my $self	= shift;
	return $self->_test('(');
}

sub _BrackettedExpression {
	my $self	= shift;
	$self->_eat('(');
	$self->__consume_ws_opt;
	$self->_Expression;
	$self->__consume_ws_opt;
	$self->_eat(')');
}

sub _Aggregate {
	my $self	= shift;
	my $op	= uc( $self->_eat( $r_AGGREGATE_CALL ) );
	$self->_eat('(');
	$self->__consume_ws_opt;
	my $distinct	= 0;
	if ($self->_test( qr/DISTINCT/i )) {
		$self->_eat( qr/DISTINCT\s*/i );
		$self->__consume_ws_opt;
		$distinct	= 1;
	}
	
	my (@expr, %options);
	if ($self->_test('*')) {
		@expr	= $self->_eat('*');
	} else {
		$self->_Expression;
		push(@expr, splice(@{ $self->{stack} }));
		if ($op eq 'GROUP_CONCAT') {
			$self->__consume_ws_opt;
			while ($self->_test(qr/,/)) {
				$self->_eat(qr/,/);
				$self->__consume_ws_opt;
				$self->_Expression;
				push(@expr, splice(@{ $self->{stack} }));
			}
			$self->__consume_ws_opt;
			if ($self->_test(qr/;/)) {
				$self->_eat(qr/;/);
				$self->__consume_ws_opt;
				$self->_eat(qr/SEPERATOR/i);
				$self->__consume_ws_opt;
				$self->_eat(qr/=/);
				$self->__consume_ws_opt;
				$self->_String;
				my ($sep)	= splice(@{ $self->{stack} });
				$options{ seperator }	= $sep;
			}
		}
	}
	$self->__consume_ws_opt;
	
	my $arg	= join(',', map { blessed($_) ? $_->as_sparql : $_ } @expr);
	if ($distinct) {
		$arg	= 'DISTINCT ' . $arg;
	}
	my $name	= sprintf('%s(%s)', $op, $arg);
	$self->_eat(')');
	
	$self->{build}{__aggregate}{ $name }	= [ (($distinct) ? "${op}-DISTINCT" : $op), \%options, @expr ];
	
	$self->_add_stack( RDF::Query::Node::Variable::ExpressionProxy->new($name) );
	
}

# [57] BuiltInCall ::= 'STR' '(' Expression ')'  | 'LANG' '(' Expression ')'  | 'LANGMATCHES' '(' Expression ',' Expression ')'  | 'DATATYPE' '(' Expression ')'  | 'BOUND' '(' Var ')'  | 'sameTerm' '(' Expression ',' Expression ')'  | 'isIRI' '(' Expression ')'  | 'isURI' '(' Expression ')'  | 'isBLANK' '(' Expression ')'  | 'isLITERAL' '(' Expression ')'  | RegexExpression
sub _BuiltInCall_test {
	my $self	= shift;
	if ($self->{__aggregate_call_ok}) {
		return 1 if ($self->_test( $r_AGGREGATE_CALL ));
	}
	return 1 if $self->_test(qr/((NOT\s+)?EXISTS)|COALESCE/i);
	return $self->_test(qr/STR|STRDT|STRLANG|BNODE|IRI|URI|LANG|LANGMATCHES|DATATYPE|BOUND|sameTerm|isIRI|isURI|isBLANK|isLITERAL|REGEX|IF/i);
}

sub _BuiltInCall {
	my $self	= shift;
	if ($self->{__aggregate_call_ok} and $self->_test( $r_AGGREGATE_CALL )) {
		$self->_Aggregate;
	} elsif ($self->_test(qr/(NOT\s+)?EXISTS/i)) {
		my $op	= $self->_eat(qr/(NOT\s+)?EXISTS/i);
		$self->__consume_ws_opt;
		$self->_GroupGraphPattern;
		my $cont	= $self->_remove_pattern;
		my $iri		= RDF::Query::Node::Resource->new( 'sparql:exists' );
		my $func	= $self->new_function_expression($iri, $cont);
		if ($op =~ /^NOT/i) {
			$self->_add_stack( $self->new_unary_expression( '!', $func ) );
		
		} else {
			$self->_add_stack( $func );
		}
	} elsif ($self->_test(qr/COALESCE|BNODE/)) {
		my $op	= $self->_eat(qr/COALESCE|BNODE/i);
		my $iri		= RDF::Query::Node::Resource->new( 'sparql:' . lc($op) );
		$self->_ArgList;
		my @args	= splice(@{ $self->{stack} });
		my $func	= $self->new_function_expression( $iri, @args );
		$self->_add_stack( $func );
	} elsif ($self->_RegexExpression_test) {
		$self->_RegexExpression;
	} else {
		my $op		= $self->_eat( qr/\w+/ );
		my $iri		= RDF::Query::Node::Resource->new( 'sparql:' . lc($op) );
		$self->__consume_ws_opt;
		$self->_eat('(');
		$self->__consume_ws_opt;
		if ($op =~ /^(STR|URI|IRI|LANG|DATATYPE|isIRI|isURI|isBLANK|isLITERAL)$/i) {
			### one-arg functions that take an expression
			$self->_Expression;
			my ($expr)	= splice(@{ $self->{stack} });
			$self->_add_stack( $self->new_function_expression($iri, $expr) );
		} elsif ($op =~ /^(STRDT|STRLANG|LANGMATCHES|sameTerm)$/i) {
			### two-arg functions that take expressions
			$self->_Expression;
			my ($arg1)	= splice(@{ $self->{stack} });
			$self->__consume_ws_opt;
			$self->_eat(',');
			$self->__consume_ws_opt;
			$self->_Expression;
			my ($arg2)	= splice(@{ $self->{stack} });
			$self->_add_stack( $self->new_function_expression($iri, $arg1, $arg2) );
		} elsif ($op =~ /^IF$/i) {
			### three-arg functions that take expressions
			$self->_Expression;
			my ($arg1)	= splice(@{ $self->{stack} });
			$self->__consume_ws_opt;
			$self->_eat(',');
			$self->__consume_ws_opt;
			$self->_Expression;
			my ($arg2)	= splice(@{ $self->{stack} });
			$self->__consume_ws_opt;
			$self->_eat(',');
			$self->__consume_ws_opt;
			$self->_Expression;
			my ($arg3)	= splice(@{ $self->{stack} });
			$self->_add_stack( $self->new_function_expression($iri, $arg1, $arg2, $arg3) );
		} else {
			### BOUND(Var)
			$self->_Var;
			my ($expr)	= splice(@{ $self->{stack} });
			$self->_add_stack( $self->new_function_expression($iri, $expr) );
		}
		$self->__consume_ws_opt;
		$self->_eat(')');
	}
}

# [58] RegexExpression ::= 'REGEX' '(' Expression ',' Expression ( ',' Expression )? ')'
sub _RegexExpression_test {
	my $self	= shift;
	return $self->_test( qr/REGEX/i );
}

sub _RegexExpression {
	my $self	= shift;
	$self->_eat( qr/REGEX/i );
	$self->__consume_ws_opt;
	$self->_eat('(');
	$self->__consume_ws_opt;
	$self->_Expression;
	my $string	= splice(@{ $self->{stack} });
	
	$self->__consume_ws_opt;
	$self->_eat(',');
	$self->__consume_ws_opt;
	$self->_Expression;
	my $pattern	= splice(@{ $self->{stack} });
	
	my @args	= ($string, $pattern);
	if ($self->_test(',')) {
		$self->_eat(',');
		$self->__consume_ws_opt;
		$self->_Expression;
		push(@args, splice(@{ $self->{stack} }));
	}
	
	$self->__consume_ws_opt;
	$self->_eat(')');
	
	my $iri		= RDF::Query::Node::Resource->new( 'sparql:regex' );
	$self->_add_stack( $self->new_function_expression( $iri, @args ) );
}

# [59] IRIrefOrFunction ::= IRIref ArgList?
sub _IRIrefOrFunction_test {
	my $self	= shift;
	$self->_IRIref_test;
}

sub _IRIrefOrFunction {
	my $self	= shift;
	$self->_IRIref;
	if ($self->_ArgList_test) {
		my ($iri)	= splice(@{ $self->{stack} });
		$self->_ArgList;
		my @args	= splice(@{ $self->{stack} });
		my $func	= $self->new_function_expression( $iri, @args );
		$self->_add_stack( $func );
	}
}

# [60] RDFLiteral ::= String ( LANGTAG | ( '^^' IRIref ) )?
sub _RDFLiteral {
	my $self	= shift;
	$self->_String;
	my @args	= splice(@{ $self->{stack} });
	if ($self->_test('@')) {
		my $lang	= $self->_eat( $r_LANGTAG );
		substr($lang,0,1)	= '';	# remove '@'
		push(@args, $lang);
	} elsif ($self->_test('^^')) {
		$self->_eat('^^');
		push(@args, undef);
		$self->_IRIref;
		my ($iri)	= splice(@{ $self->{stack} });
		push(@args, $iri->uri_value);
	}
	$self->_add_stack( RDF::Query::Node::Literal->new( @args ) );
}

# [61] NumericLiteral ::= NumericLiteralUnsigned | NumericLiteralPositive | NumericLiteralNegative
# [62] NumericLiteralUnsigned ::= INTEGER | DECIMAL | DOUBLE
# [63] NumericLiteralPositive ::= INTEGER_POSITIVE | DECIMAL_POSITIVE | DOUBLE_POSITIVE
# [64] NumericLiteralNegative ::= INTEGER_NEGATIVE | DECIMAL_NEGATIVE | DOUBLE_NEGATIVE
sub _NumericLiteral {
	my $self	= shift;
	my $sign	= 0;
	if ($self->_test('+')) {
		$self->_eat('+');
		$sign	= '+';
	} elsif ($self->_test('-')) {
		$self->_eat('-');
		$sign	= '-';
	}
	
	my $value;
	my $type;
	if ($self->_test( $r_DOUBLE )) {
		$value	= $self->_eat( $r_DOUBLE );
		my $double	= RDF::Query::Node::Resource->new( $xsd->double->uri_value );
		$type	= $double
	} elsif ($self->_test( $r_DECIMAL )) {
		$value	= $self->_eat( $r_DECIMAL );
		my $decimal	= RDF::Query::Node::Resource->new( $xsd->decimal->uri_value );
		$type	= $decimal;
	} else {
		$value	= $self->_eat( $r_INTEGER );
		my $integer	= RDF::Query::Node::Resource->new( $xsd->integer->uri_value );
		$type	= $integer;
	}
	
	if ($sign) {
		$value	= $sign . $value;
	}
	$self->_add_stack( RDF::Query::Node::Literal->new( $value, undef, $type->uri_value ) );
}

# [65] BooleanLiteral ::= 'true' | 'false'
sub _BooleanLiteral {
	my $self	= shift;
	my $bool	= $self->_eat(qr/(true|false)\b/);
	$self->_add_stack( RDF::Query::Node::Literal->new( $bool, undef, $xsd->boolean->uri_value ) );
}

# [66] String ::= STRING_LITERAL1 | STRING_LITERAL2 | STRING_LITERAL_LONG1 | STRING_LITERAL_LONG2
sub _String {
	my $self	= shift;
	my $value;
	if ($self->_test( $r_STRING_LITERAL_LONG1 )) {
		my $string	= $self->_eat( $r_STRING_LITERAL_LONG1 );
		$value		= substr($string, 3, length($string) - 6);
	} elsif ($self->_test( $r_STRING_LITERAL_LONG2 )) {
		my $string	= $self->_eat( $r_STRING_LITERAL_LONG2 );
		$value		= substr($string, 3, length($string) - 6);
	} elsif ($self->_test( $r_STRING_LITERAL1 )) {
		my $string	= $self->_eat( $r_STRING_LITERAL1 );
		$value		= substr($string, 1, length($string) - 2);
	} else { # ($self->_test( $r_STRING_LITERAL2 )) {
		my $string	= $self->_eat( $r_STRING_LITERAL2 );
		$value		= substr($string, 1, length($string) - 2);
	}
#	$value	=~ s/(${r_ECHAR})/"$1"/ge;
	$value	=~ s/\\t/\t/g;
	$value	=~ s/\\b/\n/g;
	$value	=~ s/\\n/\n/g;
	$value	=~ s/\\r/\x08/g;
	$value	=~ s/\\"/"/g;
	$value	=~ s/\\'/'/g;
	$value	=~ s/\\\\/\\/g;	# backslash must come last, so it doesn't accidentally create a new escape
	$self->_add_stack( $value );
}

# [67] IRIref ::= IRI_REF | PrefixedName
sub _IRIref_test {
	my $self	= shift;
	return $self->_test(qr/<|${r_PNAME_LN}|${r_PNAME_NS}/);
}

sub _IRIref {
	my $self	= shift;
	if ($self->_test( $r_IRI_REF )) {
		my $iri	= $self->_eat( $r_IRI_REF );
		my $node	= RDF::Query::Node::Resource->new( substr($iri,1,length($iri)-2), $self->__base );
		$self->_add_stack( $node );
	} else {
		$self->_PrefixedName;
	}
}

# [68] PrefixedName ::= PNAME_LN | PNAME_NS
sub _PrefixedName {
	my $self	= shift;
	if ($self->_test( $r_PNAME_LN )) {
		my $ln	= $self->_eat( $r_PNAME_LN );
		my ($ns,$local)	= split(/:/, $ln);
		if ($ns eq '') {
			$ns	= '__DEFAULT__';
		}
		
		unless (exists $self->{namespaces}{$ns}) {
			throw RDF::Query::Error::ParseError -text => "Syntax error: Use of undefined namespace '$ns'";
		}
		
		my $iri		= $self->{namespaces}{$ns} . $local;
		$self->_add_stack( RDF::Query::Node::Resource->new( $iri, $self->__base ) );
	} else {
		my $ns	= $self->_eat( $r_PNAME_NS );
		if ($ns eq ':') {
			$ns	= '__DEFAULT__';
		} else {
			chop($ns);
		}
		
		unless (exists $self->{namespaces}{$ns}) {
			throw RDF::Query::Error::ParseError -text => "Syntax error: Use of undefined namespace '$ns'";
		}
		
		my $iri		= $self->{namespaces}{$ns};
		$self->_add_stack( RDF::Query::Node::Resource->new( $iri, $self->__base ) );
	}
}

# [69] BlankNode ::= BLANK_NODE_LABEL | ANON
sub _BlankNode {
	my $self	= shift;
	if ($self->_test( $r_BLANK_NODE_LABEL )) {
		my $label	= $self->_eat( $r_BLANK_NODE_LABEL );
		my $id		= substr($label,2);
		$self->_add_stack( $self->new_blank($id) );
	} else {
		$self->_eat( $r_ANON );
		$self->_add_stack( $self->new_blank );
	}
}

sub _NIL {
	my $self	= shift;
	$self->_eat( $r_NIL );
	my $nil	= RDF::Query::Node::Resource->new( $rdf->nil->uri_value );
	$self->_add_stack( $nil );
}

sub __solution_modifiers {
	my $self	= shift;
	my $star	= shift;
	
	my $having_expr;
	my $aggdata	= delete( $self->{build}{__aggregate} );
	if ($aggdata) {
		my $groupby	= delete( $self->{build}{__group_by} ) || [];
		my $pattern	= $self->{build}{triples};
		my $ggp		= shift(@$pattern);
		if (my $having = delete( $self->{build}{__having} )) {
			$having_expr	= $having;
		}
		
		my $agg		= RDF::Query::Algebra::Aggregate->new( $ggp, $groupby, { expressions => [%$aggdata] } );
		push(@{ $self->{build}{triples} }, $agg);
	}
	
	my $vars	= [ @{ $self->{build}{variables} } ];
	
	{
		my @vars	= grep { $_->isa('RDF::Query::Expression::Alias') } @$vars;
		if (scalar(@vars)) {
			my $pattern	= pop(@{ $self->{build}{triples} });
			my $proj	= RDF::Query::Algebra::Extend->new( $pattern, $vars );
			push(@{ $self->{build}{triples} }, $proj);
		}
	}
	
	if ($having_expr) {
		my $pattern	= pop(@{ $self->{build}{triples} });
		my $filter	= RDF::Query::Algebra::Filter->new( $having_expr, $pattern );
		push(@{ $self->{build}{triples} }, $filter);
	}
	
	if ($self->{build}{options}{orderby}) {
		my $order	= delete $self->{build}{options}{orderby};
		my $pattern	= pop(@{ $self->{build}{triples} });
		my $sort	= RDF::Query::Algebra::Sort->new( $pattern, @$order );
		push(@{ $self->{build}{triples} }, $sort);
	}

	{
		my $pattern	= pop(@{ $self->{build}{triples} });
		my $proj	= RDF::Query::Algebra::Project->new( $pattern, $vars );
		push(@{ $self->{build}{triples} }, $proj);
	}
	
	if ($self->{build}{options}{distinct}) {
		delete $self->{build}{options}{distinct};
		my $pattern	= pop(@{ $self->{build}{triples} });
		my $sort	= RDF::Query::Algebra::Distinct->new( $pattern );
		push(@{ $self->{build}{triples} }, $sort);
	}
	
	if (exists $self->{build}{options}{offset}) {
		my $offset		= delete $self->{build}{options}{offset};
		my $pattern		= pop(@{ $self->{build}{triples} });
		my $offseted	= RDF::Query::Algebra::Offset->new( $pattern, $offset );
		push(@{ $self->{build}{triples} }, $offseted);
	}
	
	if (exists $self->{build}{options}{limit}) {
		my $limit	= delete $self->{build}{options}{limit};
		my $pattern	= pop(@{ $self->{build}{triples} });
		my $limited	= RDF::Query::Algebra::Limit->new( $pattern, $limit );
		push(@{ $self->{build}{triples} }, $limited);
	}
}

################################################################################

=item C<< error >>

Returns the error encountered during the last parse.

=cut

sub error {
	my $self	= shift;
	return $self->{error};
}

sub _add_patterns {
	my $self	= shift;
	my @triples	= @_;
	my $container	= $self->{ pattern_container_stack }[0];
	push( @{ $container }, @triples );
}

sub _remove_pattern {
	my $self	= shift;
	my $container	= $self->{ pattern_container_stack }[0];
	my $pattern		= pop( @{ $container } );
	return $pattern;
}

sub _peek_pattern {
	my $self	= shift;
	my $container	= $self->{ pattern_container_stack }[0];
	my $pattern		= $container->[-1];
	return $pattern;
}

sub _push_pattern_container {
	my $self	= shift;
	my $cont	= [];
	unshift( @{ $self->{ pattern_container_stack } }, $cont );
	return $cont;
}

sub _pop_pattern_container {
	my $self	= shift;
	my $cont	= shift( @{ $self->{ pattern_container_stack } } );
	return $cont;
}

sub _add_stack {
	my $self	= shift;
	my @items	= @_;
	push( @{ $self->{stack} }, @items );
}

sub _add_filter {
	my $self	= shift;
	my @filters	= shift;
	push( @{ $self->{filters} }, @filters );
}

sub _eat {
	my $self	= shift;
	my $thing	= shift;
	if (not(length($self->{tokens}))) {
		$self->_syntax_error("No tokens left");
	}
	
# 	if (substr($self->{tokens}, 0, 1) eq '^') {
# 		Carp::cluck( "eating $thing with input $self->{tokens}" );
# 	}
	
	if (blessed($thing) and $thing->isa('Regexp')) {
		if ($self->{tokens} =~ /^$thing/) {
			my $match	= $&;
			substr($self->{tokens}, 0, length($match))	= '';
			return $match;
		}
		
		$self->_syntax_error( "Expected $thing" );
	} elsif (looks_like_number( $thing )) {
		my ($token)	= substr( $self->{tokens}, 0, $thing, '' );
		return $token
	} else {
		### thing is a string
		if (substr($self->{tokens}, 0, length($thing)) eq $thing) {
			substr($self->{tokens}, 0, length($thing))	= '';
			return $thing;
		} else {
			$self->_syntax_error( "Expected $thing" );
		}
	}
	print $thing;
	throw RDF::Query::Error;
}

sub _syntax_error {
	my $self	= shift;
	my $thing	= shift;
	my $expect	= $thing;

	my $level	= 2;
	while (my $sub = (caller($level++))[3]) {
		if ($sub =~ m/::_([A-Z]\w*)$/) {
			$expect	= $1;
			last;
		}
	}
	
	my $l		= Log::Log4perl->get_logger("rdf.query.parser.sparql");
	if ($l->is_debug) {
		$l->logcluck("Syntax error eating $thing with input <<$self->{tokens}>>");
	}
	
	my $near	= "'" . substr($self->{tokens}, 0, 20) . "...'";
	$near		=~ s/[\r\n ]+/ /g;
	if ($thing) {
		throw RDF::Query::Error::ParseError -text => "Syntax error: $thing in $expect near $near";
	} else {
		throw RDF::Query::Error::ParseError -text => "Syntax error: Expected $expect near $near";
	}
}

sub _test {
	my $self	= shift;
	my $thing	= shift;
	if (blessed($thing) and $thing->isa('Regexp')) {
		if ($self->{tokens} =~ m/^$thing/) {
			return 1;
		} else {
			return 0;
		}
	} else {
		if (substr($self->{tokens}, 0, length($thing)) eq $thing) {
			return 1;
		} else {
			return 0;
		}
	}
}

sub _ws_test {
	my $self	= shift;
	unless (length($self->{tokens})) {
		return 0;
	}
	
	if ($self->{tokens} =~ m/^[\t\r\n #]/) {
		return 1;
	} else {
		return 0;
	}
}

sub _ws {
	my $self	= shift;
	### #x9 | #xA | #xD | #x20 | comment
	if ($self->_test('#')) {
		$self->_eat(qr/#[^\x0d\x0a]*.?/);
	} else {
		$self->_eat(qr/[\n\r\t ]/);
	}
}

sub __consume_ws_opt {
	my $self	= shift;
	if ($self->_ws_test) {
		$self->__consume_ws;
	}
}

sub __consume_ws {
	my $self	= shift;
	$self->_ws;
	while ($self->_ws_test()) {
		$self->_ws()
	}
}

sub __base {
	my $self	= shift;
	my $build	= $self->{build};
	if (defined($build->{base})) {
		return $build->{base};
	} else {
		return;
	}
}

sub __new_statement {
	my $self	= shift;
	my @nodes	= @_;
	if (my $graph = $self->{named_graph} and $self->{named_graph}->isa('RDF::Trine::Node::Resource')) {
		return RDF::Query::Algebra::Quad->new( @nodes, $graph );
	} else {
		return RDF::Query::Algebra::Triple->_new( @nodes );
	}
}

sub __new_path {
	my $self	= shift;
	my $start	= shift;
	my $pdata	= shift;
	my $end		= shift;
	(undef, my $op, my @nodes)	= @$pdata;
	@nodes	= map { $self->__strip_path( $_ ) } @nodes;
	if (my $graph = $self->{named_graph} and $self->{named_graph}->isa('RDF::Trine::Node::Resource')) {
		return RDF::Query::Algebra::Path->new( $start, [$op, @nodes], $end, $graph );
	} else {
		return RDF::Query::Algebra::Path->new( $start, [$op, @nodes], $end );
	}
}

sub __strip_path {
	my $self	= shift;
	my $path	= shift;
	if (blessed($_)) {
		return $_;
	} elsif (reftype($_) eq 'ARRAY' and $_->[0] eq 'PATH') {
		(undef, my $op, my @nodes)	= @$path;
		return [$op, map { $self->__strip_path($_) } @nodes];
	} else {
		return $_;
	}
}

sub __new_bgp {
	# fix up BGPs that might actually have property paths in them. split those
	# out as their own path algebra objects, and join them with the bgp with a
	# ggp if necessary
	my $self		= shift;
	my @patterns	= @_;
	my @paths		= grep { reftype($_->predicate) eq 'ARRAY' and $_->predicate->[0] eq 'PATH' } @patterns;
	my @triples		= grep { blessed($_->predicate) } @patterns;
	if (scalar(@patterns) > scalar(@paths) + scalar(@triples)) {
		Carp::cluck "more than just triples and paths passed to __new_bgp: " . Dumper(\@patterns);
	}
	my $bgp			= RDF::Query::Algebra::BasicGraphPattern->new( @triples );
	if (@paths) {
		my @p;
		foreach my $p (@paths) {
			my $start	= $p->subject;
			my $end		= $p->object;
			my $pdata	= $p->predicate;
			push(@p, $self->__new_path( $start, $pdata, $end ));
		}
		my $pgroup	= (scalar(@p) == 1)
					? $p[0]
					: RDF::Query::Algebra::GroupGraphPattern->new( @p );
		if (scalar(@triples)) {
			return RDF::Query::Algebra::GroupGraphPattern->new( $bgp, $pgroup );
		} else {
			return $pgroup;
		}
	} else {
		return $bgp;
	}
}

1;

__END__

=back

=cut
