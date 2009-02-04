#include "index.h"

int _hx_index_iter_prime_first_result( hx_index_iter* iter );


/**

	Arguments index_order = {a,b,c} map the positions of a triple to the
	ordering of the index.
	
	(a,b,c) = (0,1,2)	==> (s,p,o) index
	(a,b,c) = (1,0,2)	==> (p,s,o) index
	(a,b,c) = (2,1,0)	==> (o,p,s) index

**/

hx_index* hx_new_index ( int* index_order ) {
	int a	= index_order[0];
	int b	= index_order[1];
	int c	= index_order[2];
	hx_index* i	= (hx_index*) calloc( 1, sizeof( hx_index ) );
	i->order[0]	= a;
	i->order[1]	= b;
	i->order[2]	= c;
	i->head		= hx_new_head();
	return i;
}

int hx_free_index ( hx_index* i ) {
	hx_free_head( i->head );
	free( i );
	return 0;
}

// XXX replace the use of ->used, etc. with iterators (preserves abstraction)
int hx_index_debug ( hx_index* index ) {
	hx_head* h	= index->head;
	fprintf(
		stderr,
		"index: %p\n  -> head: %p\n  -> order [%d, %d, %d]\n  -> triples:\n",
		(void*) index,
		(void*) h,
		(int) index->order[0],
		(int) index->order[1],
		(int) index->order[2]
	);
	rdf_node triple_ordered[3];
	
	hx_head_iter* hiter	= hx_head_new_iter( h );
	int i	= 0;
	while (!hx_head_iter_finished( hiter )) {
		hx_vector* v;
		hx_head_iter_current( hiter, &(triple_ordered[ index->order[ 0 ] ]), &v );
		
		for (int j = 0; j < v->used; j++) {
			hx_terminal* t	= v->ptr[j].terminal;
			triple_ordered[ index->order[ 1 ] ]	= v->ptr[j].node;
			for (int k = 0; k < t->used;  k++) {
				rdf_node n	= t->ptr[k];
				triple_ordered[ index->order[ 2 ] ]	= n;
				fprintf( stderr, "\t{ %d, %d, %d }\n", (int) triple_ordered[0], (int) triple_ordered[1], (int) triple_ordered[2] );
			}
		}
		
		hx_head_iter_next( hiter );
		i++;
	}
	hx_free_head_iter( hiter );
	
	return 0;
}

int hx_index_add_triple ( hx_index* index, rdf_node s, rdf_node p, rdf_node o ) {
	rdf_node triple_ordered[3];
	triple_ordered[0]	= s;
	triple_ordered[1]	= p;
	triple_ordered[2]	= o;
	rdf_node index_ordered[3];
	for (int i = 0; i < 3; i++) {
		index_ordered[ i ]	= triple_ordered[ index->order[ i ] ];
	}
//	fprintf( stderr, "add_triple index order: { %d, %d, %d }\n", (int) index_ordered[0], (int) index_ordered[1], (int) index_ordered[2] );
	
	hx_head* h	= index->head;
	hx_vector* v	= NULL;
	hx_terminal* t;
	
	if ((v = hx_head_get_vector( h, index_ordered[0] )) == NULL) {
//		fprintf( stderr, "adding missing vector for node %d\n", (int) index_ordered[0] );
		v	= hx_new_vector();
		hx_head_add_vector( h, index_ordered[0], v );
	}
	
	if ((t = hx_vector_get_terminal( v, index_ordered[1] )) == NULL) {
		t	= hx_new_terminal();
		hx_vector_add_terminal( v, index_ordered[1], t );
	}
	
	hx_terminal_add_node( t, index_ordered[2] );
	return 0;
}

int hx_index_remove_triple ( hx_index* index, rdf_node s, rdf_node p, rdf_node o ) {
	rdf_node triple_ordered[3];
	triple_ordered[0]	= s;
	triple_ordered[1]	= p;
	triple_ordered[2]	= o;
	rdf_node index_ordered[3];
	for (int i = 0; i < 3; i++) {
		index_ordered[ i ]	= triple_ordered[ index->order[ i ] ];
	}
	
	hx_head* h	= index->head;
	hx_vector* v;
	hx_terminal* t;
	
	if ((v = hx_head_get_vector( h, index_ordered[0] )) == NULL) {
		// no vector for this node... do nothing.
		return 1;
	}
	
	if ((t = hx_vector_get_terminal( v, index_ordered[1] )) == NULL) {
		// no terminal for this node... do nothing.
		return 1;
	}
	
	hx_terminal_remove_node( t, index_ordered[2] );
	
	if (hx_terminal_size( t ) == 0) {
		// no more nodes in this terminal list... remove it from the vector.
		hx_vector_remove_terminal( v, index_ordered[1] );
		
		if (hx_vector_size( v ) == 0) {
			// no more terminal lists in this vector... remove it from the head.
			hx_head_remove_vector( h, index_ordered[0] );
		}
	}
	
	return 0;
}

uint64_t hx_index_triples_count ( hx_index* index ) {
	return hx_head_triples_count( index->head );
}

size_t hx_index_memory_size ( hx_index* i ) {
	uint64_t size	= sizeof( hx_index ) + hx_head_memory_size( i->head );
	return size;
}

hx_index_iter* hx_index_new_iter ( hx_index* index ) {
	hx_index_iter* iter	= (hx_index_iter*) calloc( 1, sizeof( hx_index_iter ) );
	iter->flags			= 0;
	iter->started		= 0;
	iter->finished		= 0;
	iter->node_mask_a	= (rdf_node) 0;
	iter->node_mask_b	= (rdf_node) 0;
	iter->node_mask_c	= (rdf_node) 0;
	iter->index			= index;
	return iter;
}

hx_index_iter* hx_index_new_iter1 ( hx_index* index, rdf_node a, rdf_node b, rdf_node c ) {
	hx_index_iter* iter	= hx_index_new_iter( index );
	iter->node_mask_a	= a;
	iter->node_mask_b	= b;
	iter->node_mask_c	= c;
	return iter;
}

int hx_free_index_iter ( hx_index_iter* iter ) {
	if (iter->head_iter != NULL)
		hx_free_head_iter( iter->head_iter );
	if (iter->vector_iter != NULL)
		hx_free_vector_iter( iter->vector_iter );
	if (iter->terminal_iter != NULL)
		hx_free_terminal_iter( iter->terminal_iter );
	free( iter );
	return 0;
}

int hx_index_iter_finished ( hx_index_iter* iter ) {
	if (iter->started == 0) {
		_hx_index_iter_prime_first_result( iter );
	}
	return iter->finished;
}

int hx_index_iter_current ( hx_index_iter* iter, rdf_node* s, rdf_node* p, rdf_node* o ) {
	if (iter->started == 0) {
		_hx_index_iter_prime_first_result( iter );
	}
	if (iter->finished == 1) {
		return 1;
	}
	
	rdf_node triple_ordered[3];
//	fprintf( stderr, "iter: %p\n", iter );
	hx_index* index	= iter->index;
//	fprintf( stderr, "index: %p\n", iter->index );
	hx_vector* v;
	
// 	fprintf( stderr, "triple position %d comes from the head\n", index->order[0] );
	hx_head_iter_current( iter->head_iter, &(triple_ordered[ index->order[0] ]), &v );
	
	hx_terminal* t;
// 	fprintf( stderr, "triple position %d comes from the vector\n", index->order[1] );
	hx_vector_iter_current( iter->vector_iter, &(triple_ordered[ index->order[1] ]), &t );
	
// 	fprintf( stderr, "triple position %d comes from the terminal\n", index->order[2] );
	hx_terminal_iter_current( iter->terminal_iter, &(triple_ordered[ index->order[2] ]) );
	
	*s	= triple_ordered[0];
	*p	= triple_ordered[1];
	*o	= triple_ordered[2];
// 	fprintf( stderr, "hx_iter_current: got nodes (%d, %d, %d)\n", (int) *s, (int) *p, (int) *o );
	return 0;
}

int _hx_index_iter_prime_first_result( hx_index_iter* iter ) {
	iter->started	= 1;
	hx_index* index	= iter->index;
	
	iter->head_iter	= hx_head_new_iter( index->head );
	if (iter->node_mask_a != (rdf_node) 0) {
		if (hx_head_iter_seek( iter->head_iter, iter->node_mask_a ) != 0) {
			iter->finished	= 1;
			return 1;
		}
	}
	
	if (hx_head_iter_finished( iter->head_iter )) {
		hx_free_head_iter( iter->head_iter );
		iter->head_iter	= NULL;
		iter->finished	= 1;
		return 1;
	} else {
		rdf_node n;
		hx_vector* v;
		hx_head_iter_current( iter->head_iter, &n, &v );
		iter->vector_iter	= hx_vector_new_iter( v );
		if (iter->node_mask_b != (rdf_node) 0) {
			if (hx_vector_iter_seek( iter->vector_iter, iter->node_mask_b ) != 0) {
				iter->finished	= 1;
				return 1;
			}
		}
		
		if (hx_vector_iter_finished( iter->vector_iter )) {
			hx_free_vector_iter( iter->vector_iter );
			iter->vector_iter	= NULL;
			iter->finished	= 1;
			return 1;
		} else {
			hx_terminal* t;
			hx_vector_iter_current( iter->vector_iter, &n, &t );
			iter->terminal_iter	= hx_terminal_new_iter( t );
			if (iter->node_mask_c != (rdf_node) 0) {
				if (hx_terminal_iter_seek( iter->terminal_iter, iter->node_mask_c ) != 0) {
					iter->finished	= 1;
					return 1;
				}
			}
			
			if (hx_terminal_iter_finished( iter->terminal_iter )) {
				hx_free_terminal_iter( iter->terminal_iter );
				iter->terminal_iter	= NULL;
				iter->finished	= 1;
				return 1;
			}
		}
	}
	return 0;
}

int hx_index_iter_next ( hx_index_iter* iter ) {
	if (iter->started == 0) {
		_hx_index_iter_prime_first_result( iter );
		if (iter->finished == 1) {
			return 1;
		}
	}
	
	int hr, vr, tr;
NEXTTERMINAL:
	tr	= hx_terminal_iter_next( iter->terminal_iter );
	if (tr == 0 && (iter->node_mask_c == (rdf_node) 0)) {
//		fprintf( stderr, "got next terminal\n" );
		return 0;
	} else {
NEXTVECTOR:
		vr	= hx_vector_iter_next( iter->vector_iter );
		if (vr == 0 && (iter->node_mask_b == (rdf_node) 0)) {
//			fprintf( stderr, "got next vector\n" );
			hx_free_terminal_iter( iter->terminal_iter );
			iter->terminal_iter	= NULL;
			
			// set up terminal iterator
			rdf_node n;
			hx_terminal* t;
			hx_vector_iter_current( iter->vector_iter, &n, &t );
			iter->terminal_iter	= hx_terminal_new_iter( t );
			if (iter->node_mask_c != (rdf_node) 0) {
				if (hx_terminal_iter_seek( iter->terminal_iter, iter->node_mask_c ) != 0) {
					goto NEXTVECTOR;
				}
			}
			return 0;
		} else {
NEXTHEAD:
			hr	= hx_head_iter_next( iter->head_iter );
			if (hr == 0 && (iter->node_mask_a == (rdf_node) 0)) {
//				fprintf( stderr, "got next head\n" );
				hx_free_terminal_iter( iter->terminal_iter );
				iter->terminal_iter	= NULL;
				hx_free_vector_iter( iter->vector_iter );
				iter->vector_iter	= NULL;
				
				// set up vector and terminal iterators
				rdf_node n;
				hx_vector* v;
				hx_terminal* t;
				hx_head_iter_current( iter->head_iter, &n, &v );
				iter->vector_iter	= hx_vector_new_iter( v );
				if (iter->node_mask_b != (rdf_node) 0) {
					if (hx_vector_iter_seek( iter->vector_iter, iter->node_mask_b ) != 0) {
						goto NEXTHEAD;
					}
				}
				
				hx_vector_iter_current( iter->vector_iter, &n, &t );
				iter->terminal_iter	= hx_terminal_new_iter( t );
				if (iter->node_mask_c != (rdf_node) 0) {
					if (hx_terminal_iter_seek( iter->terminal_iter, iter->node_mask_c ) != 0) {
						goto NEXTVECTOR;
					}
				}
				return 0;
			} else {
				hx_free_head_iter( iter->head_iter );
				iter->head_iter	= NULL;
				hx_free_vector_iter( iter->vector_iter );
				iter->vector_iter	= NULL;
				hx_free_terminal_iter( iter->terminal_iter );
				iter->terminal_iter	= NULL;
				iter->finished	= 1;
				return 1;
			}
		}
	}
	
	return 0;
}


int hx_index_write( hx_index* i, FILE* f ) {
	fputc( 'I', f );
	fwrite( i->order, sizeof( int ), 3, f );
	return hx_head_write( i->head, f );
}

hx_index* hx_index_read( FILE* f, int buffer ) {
	size_t read;
	int c	= fgetc( f );
	if (c != 'I') {
		fprintf( stderr, "*** Bad header cookie trying to read index from file.\n" );
		return NULL;
	}
	hx_index* i	= (hx_index*) calloc( 1, sizeof( hx_index ) );
	read	= fread( i->order, sizeof( int ), 3, f );
	if (read == 0 || (i->head = hx_head_read( f, buffer )) == NULL) {
		free( i );
		return NULL;
	} else {
		return i;
	}
}
