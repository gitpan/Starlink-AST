/*

  AST.xs

  Copyright (C) 2004 Tim Jenness. All Rights Reserved.

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful,but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program; if not, write to the Free Software Foundation, Inc., 59 Temple
Place,Suite 330, Boston, MA  02111-1307, USA

*/

#ifdef __cplusplus
extern "C" {
#endif
#include "EXTERN.h"   /* std perl include */
#include "perl.h"     /* std perl include */
#include "XSUB.h"     /* XSUB include */
#include "ppport.h"
#ifdef __cplusplus
}
#endif

/* for some reason ppport.h does not currently have CopFILE defined */
#ifndef CopFILE 
#define CopFILE(s)  "<unknown>"
#endif
#ifndef CopLINE
#define CopLINE(s)  -1
#endif

/* typedef some common types so that the typemap can bless constants
   into correct namespaces */

typedef int StatusType;
typedef int WcsMapType;

#include "ast.h"
#include "grf.h"

/* The following definitions are required for backwards compatible
   Since AST version 2 does not have these.
*/

#if ( AST_MAJOR_VERS >= 2 )
# define HASSPECFRAME
# define HASSPECMAP
# define HASSPECADD
# define HASSETREFPOS
# define HASGETREFPOS
# define HASGETACTIVEUNIT
# define HASSETACTIVEUNIT
#else
typedef void AstSpecFrame;
typedef void AstSpecMap;
#endif

#if ( AST_MAJOR_VERS >= 3 )
#define HASPOLYMAP
#define HASGRISMMAP
#define HASSHIFTMAP
#define HASRATE
#else
typedef void AstPolyMap;
typedef void AstGrismMap;
typedef void AstShiftMap;
#endif

#if ( (AST_MAJOR_VERS == 3 && AST_MINOR_VERS >= 1) || AST_MAJOR_VERS >= 4 )
#define HASXMLCHAN
#else
typedef void AstXmlChan;
#endif

#if ( (AST_MAJOR_VERS == 3 && AST_MINOR_VERS >= 2) || AST_MAJOR_VERS >= 4 )
#define HASTRANMAP
#else
typedef void AstTranMap;
#endif

/* Helper functions */
#include "arrays.h"
#include "astTypemap.h"

char ** pack1Dchar( AV * avref ) {
  int i;
  SV ** elem;
  char ** outarr;
  int len;
  STRLEN linelen;

  /* number of elements */
  len  = av_len( avref ) + 1;
  /* Temporary storage */
  outarr = get_mortalspace( len,'v');

  for (i=0; i<len; i++) {
    elem = av_fetch( avref, i, 0);
    if (elem == NULL ) {
      /* undef */
    } else {
      outarr[i] = SvPV( *elem, linelen);
    }
  }
  return outarr;
}


/* Exception handler callback */

void astThrowException ( int status, AV* errorstack ) {
  dSP;

  ENTER;
  SAVETMPS;

  PUSHMARK(sp);

  /* Push the status and array onto the arg stack */
  XPUSHs(sv_2mortal(newSViv(status))); 
  XPUSHs(newRV_noinc((SV*) errorstack));

  PUTBACK;

  /* Now call the perl code to throw the exception */
  call_pv("Starlink::AST::Status::ThrowError", G_DISCARD );

  FREETMPS;
  LEAVE;

}

/* Callbacks */

/* sourceWrap is called by the fitschan constructor immediately and not
   by the Read method. This means that there are no worries about 
   reference counting or keeping copies of the function around.
 */

static char *sourceWrap( const char *(*source)() ) {
  dSP;
  SV * cb;
  SV * retsv;
  int count;
  STRLEN len;
  char * line;
  char * retval;

  /* Return directly if ast status is set. */
  if ( !astOK ) return NULL;
  if ( source == NULL ) {
    astError( AST__INTER, "source function called without Perl callback");
    return NULL;
  }

  /* Need to cast the source argument to a SV*  */
  cb = (SV*) source;

  /* call the callback with the supplied line */
  ENTER;
  SAVETMPS;

  PUSHMARK(sp);
  PUTBACK;

  count = perl_call_sv( cb, G_NOARGS | G_SCALAR | G_EVAL );

  ReportPerlError( AST__INTER );

  SPAGAIN ;

  if (astOK) {
    if (count != 1) {
      astError( AST__INTER, "Returned more than one arg from channel source");
    } else {
      retsv = POPs;

      if (SvOK(retsv)) {
	line = SvPV(retsv, len);

	/* The sourceWrap function must return the line in memory
	   allocated using the AST memory allocator */
	retval = astMalloc( len + 1 );
	if ( retval != NULL ) {
	  strcpy( retval, line );
	}
      } else {
	retval = NULL;
      }
    }
  }

  PUTBACK;
  FREETMPS;
  LEAVE;

  return retval;
}

static void sinkWrap( void (*sink)(const char *), const char *line ) {
  dSP;
  SV * cb;
  SV * myobject;

  /* Return directly if ast status is set. */
  if ( !astOK ) return;

  /* Need to cast the sink argument to a SV*  */
  myobject = (SV*) sink;

  cb = getPerlObjectAttr( myobject, "_sink" );

  if (cb == NULL) {
    astError( AST__INTER, "Callback in channel 'sink' not defined!");
    return;
  }


  /* call the callback with the supplied line */
  ENTER;
  SAVETMPS;

  PUSHMARK(sp);
  XPUSHs( sv_2mortal( newSVpv( (char*)line, strlen(line) )));
  PUTBACK;

  perl_call_sv( SvRV(cb), G_DISCARD | G_VOID | G_EVAL );

  ReportPerlError( AST__INTER );

  FREETMPS;
  LEAVE;

}


/* Need to allocate a mutex to prevent threads accessing
   the AST simultaneously. May need to protect this from
   non-threaded perl */

#ifdef USE_ITHREADS
static perl_mutex AST_mutex;
#endif

/* An array to store the messages coming from the error system */
AV* ErrBuff;

/* We need to make sure that ast routines are called in a thread-safe
   manner since the underlying AST library is not thread-safe because
   of the error system. Use Mark's JNIAST technique */

#define ASTCALL(code) \
  STMT_START { \
    int my_xsstatus_val = 0; \
    int *my_xsstatus = &my_xsstatus_val; \
    int *old_ast_status; \
    AV* local_err; \
    MUTEX_LOCK(&AST_mutex); \
    My_astClearErrMsg(); \
    old_ast_status = astWatch( my_xsstatus ); \
    code \
    astWatch( old_ast_status ); \
    /* Need to remove the MUTEX before we croak [but must copy the error buffer] */ \
    My_astCopyErrMsg( &local_err ); \
    MUTEX_UNLOCK(&AST_mutex); \
    if ( *my_xsstatus != 0 ) { \
      astThrowException( *my_xsstatus, local_err ); \
    } \
  } STMT_END;


/* When we call plot routines, we need to register the plot object
   in a global variable so that the plotting infrastructure can get
   at the callbacks */

#define PLOTCALL(grfobject,code) \
  ASTCALL( \
    Perl_storeGrfObject( grfobject ); \
    code \
    Perl_clearGrfObject(); \
  )

/* This is the error handler.
 Store error messages in an array. Need to worry about thread-local storage
 very soon.
 */

void astPutErr_ ( int status, const char * message ) {
  /* the av_clear decrements the refcnt of the SV entries */
  av_push(ErrBuff, newSVpv((char*)message, 0) );
}

void My_astClearErrMsg () {
  av_clear( ErrBuff );
}

/* routine to copy the error messages from the global array to a private
   array so that we can release the Mutex before the exception is thrown.
   Creates a new mortal AV and populates it.

   This is required because astPutErr can only use the static version
   of the array.
 */

void My_astCopyErrMsg ( AV ** newbuff ) {
  int i;
  SV ** elem;

  *newbuff = newAV();
  for (i = 0; i <= av_len( ErrBuff ) ; i++ ) {
    elem = av_fetch( ErrBuff, i, 0);
    if (elem != NULL ) {
      av_push( *newbuff, sv_mortalcopy( *elem )); 
    }
  }

}

MODULE = Starlink::AST     PACKAGE = Starlink::AST

BOOT:
          MUTEX_INIT(&AST_mutex);
          ErrBuff = newAV();
          
double
AST__BAD()
 CODE:
#ifdef AST__BAD
    RETVAL = AST__BAD;
#else
    Perl_croak(aTHX_ "Constant AST__BAD not defined\n");
#endif
 OUTPUT:
  RETVAL
          
MODULE = Starlink::AST     PACKAGE = Starlink::AST PREFIX = ast


void
astBegin()
 CODE:
  ASTCALL(
    astBegin;
  )


void
astEnd()
 CODE:
  ASTCALL(
    astEnd;
  )

# Can be called as class method or function

int
astVersion( ... )
 CODE:
#if ( AST_MAJOR_VERS >= 2 )
  ASTCALL(
   RETVAL = astVersion;
  )
#else
   Perl_croak(aTHX_ "astVersion: Please upgrade to AST V2.x or greater");
#endif
 OUTPUT:
  RETVAL

void
astIntraReg()
 CODE:
   Perl_croak(aTHX_ "astIntraReg Not yet implemented\n");

# The following functions are associated with AST internal status
# They can only be called from within an AST callback (eg the
# graphics system since they do not MUTEX and they do not switch
# the internal status variable.

# Note the use of _ in name

# No need to make this private but we need to make sure
# this is called from within a mutex (so a callback is okay)
# Call is as _OK. but without changing the current status integer

bool
ast_OK()
 CODE:
  RETVAL = astOK;
 OUTPUT:
  RETVAL

# Called only from within AST callbacks. No MUTEX locking.

void
ast_Error( status, message)
  StatusType status
  char * message
 CODE:
  astError( status, message); 


# Call only from within an AST callback

void
ast_ClearStatus()
 CODE:
   astClearStatus;

void
ast_SetStatus( status )
  StatusType status
 CODE:
   astSetStatus( status );

StatusType
ast_Status()
 CODE:
   RETVAL = astStatus;
 OUTPUT:
  RETVAL

MODULE = Starlink::AST  PACKAGE = Starlink::AST::Status

# Translate status values
int
value( this )
  StatusType this
 CODE:
  RETVAL = this;
 OUTPUT:
  RETVAL

MODULE = Starlink::AST  PACKAGE = Starlink::AST::Frame

AstFrame *
new( class, naxes, options )
  char * class
  int naxes
  char * options
 CODE:
  ASTCALL(
   RETVAL = astFrame( naxes, options );
  )
 OUTPUT:
  RETVAL

MODULE = Starlink::AST  PACKAGE = Starlink::AST::FrameSet

AstFrameSet *
new( class, frame, options )
  char * class
  AstFrame * frame
  char * options
 CODE:
  ASTCALL(
   RETVAL = astFrameSet( frame, options );
  )
 OUTPUT:
  RETVAL

MODULE = Starlink::AST  PACKAGE = Starlink::AST::CmpFrame

AstCmpFrame *
new( class, frame1, frame2, options )
  char * class
  AstFrame * frame1
  AstFrame * frame2
  char * options
 CODE:
  ASTCALL(
   RETVAL = astCmpFrame( frame1, frame2, options );
  )
 OUTPUT:
  RETVAL

MODULE = Starlink::AST  PACKAGE = Starlink::AST::CmpMap

AstCmpMap *
new( class, map1, map2, series, options )
  char * class
  AstMapping * map1
  AstMapping * map2
  int series
  char * options
 CODE:
  ASTCALL(
   RETVAL = astCmpMap( map1, map2, series, options );
  )
 OUTPUT:
  RETVAL

MODULE = Starlink::AST  PACKAGE = Starlink::AST::Channel

# Need to add proper support for the callbacks. Currently rely on the
# returned object to keep a reference to the callback.

# Note that we use inheritance here so we have to switch on the basis
# of the supplied class. Things will get difficult if people start
# adding their own subclasses since I am only looking at substring
# matches.

SV *
_new( class, sourcefunc, sinkfunc, options )
  char * class
  SV * sourcefunc
  SV * sinkfunc
  char * options;
 PREINIT:
  SV ** value;
  SV * sink = NULL;
  SV * source = NULL;
  AstChannel * channel;
  AstFitsChan * fitschan;
  AstXmlChan * xmlchan;
  bool has_source = 0;
  bool has_sink = 0;
 CODE:
  /* create the object without a pointer */
  RETVAL = createPerlObject( class, NULL );

  /* Decide whether to register a callback with the sink/source.
     Do this rather than always registering callback for efficiency reasons
     and because I am not sure if the presence of a callback affects the
     behaviour of the channel. */

  /* First see whether we were given valid callbacks */
  if (SvOK(sourcefunc) && SvROK(sourcefunc) && 
        SvTYPE(SvRV(sourcefunc)) == SVt_PVCV) has_source = 1;
  if (SvOK(sinkfunc) && SvROK(sinkfunc) && 
        SvTYPE(SvRV(sinkfunc)) == SVt_PVCV) has_sink = 1;

  if ( has_source || has_sink) {
    /* Take a reference to the object but do not increment the REFCNT. We
       Want this to be freed when the perl object disappears. */
    /* only take one reference */

    /* For sink functions we have to keep them around in the object 
       since they are called when the object is annulled. */
    SV * rv = newRV_noinc( SvRV( RETVAL ));
    if (has_sink) {
      /* Store reference to object */
      sink = rv;
      /* and store the actual sink callback in the object */
      setPerlObjectAttr( RETVAL, "_sink", newRV( SvRV(sinkfunc) ));
    }

    /* Source functions are called immediately so we can simply
       pass the CV directly to the constructor */
    if (has_source) source = sourcefunc;
  }

  /* Need to use astChannelFor style interface so that we can register
     a fixed callback and a reference to a CV */
  if ( strstr( class, "Channel") != NULL) {
   ASTCALL(
    channel = astChannelFor( (const char *(*)()) source, sourceWrap,
                             (void (*)( const char * )) sink, sinkWrap, options );
   )
   if (astOK) setPerlAstObject( RETVAL, (AstObject*)channel );
  } else if (strstr( class, "FitsChan") != NULL) {
   ASTCALL(
    fitschan = astFitsChanFor( (const char *(*)()) source, sourceWrap,
                             (void (*)( const char * )) sink, sinkWrap, options );
   )
   if (astOK) setPerlAstObject( RETVAL, (AstObject*)fitschan );
  } else if (strstr( class, "XmlChan") != NULL ) {
#ifndef HASXMLCHAN   
   Perl_croak(aTHX_ "XmlChan: Please upgrade to AST V3.1 or greater");
#else
   ASTCALL(
    xmlchan = astXmlChanFor( (const char *(*)()) source, sourceWrap,
                             (void (*)( const char * )) sink, sinkWrap, options );
   )
   if (astOK) setPerlAstObject( RETVAL, (AstObject*)xmlchan );
#endif
  } else {
     Perl_croak(aTHX_ "Channel of class %s not recognized.", class );
  }
 OUTPUT:
  RETVAL


MODULE = Starlink::AST  PACKAGE = Starlink::AST::GrismMap

AstGrismMap *
new( class, options )
  char * class
  char * options
 CODE:
#ifndef HASGRISMMAP 
   Perl_croak(aTHX_ "GrismMap: Please upgrade to AST V3.x or greater");
#else
  ASTCALL(
   RETVAL = astGrismMap( options );
  )
#endif
 OUTPUT:
  RETVAL

MODULE = Starlink::AST  PACKAGE = Starlink::AST::IntraMap

AstIntraMap *
new( class, name, nin, nout, options )
  char * class
  char * name
  int nin
  int nout
  char * options
 CODE:
  ASTCALL(
   RETVAL = astIntraMap( name, nin, nout, options );
  )
 OUTPUT:
  RETVAL

MODULE = Starlink::AST  PACKAGE = Starlink::AST::LutMap

AstLutMap *
new( class, lut, start, inc, options )
  char * class
  AV* lut
  double start
  double inc
  char * options
 PREINIT:
  int nlut;
  double * clut;
 CODE:
  nlut = av_len( lut );
  clut = pack1D( newRV_noinc((SV*)lut), 'd' );
  ASTCALL(
   RETVAL = astLutMap( nlut, clut, start, inc, options );
  )
 OUTPUT:
  RETVAL

MODULE = Starlink::AST  PACKAGE = Starlink::AST::MathMap

AstMathMap *
new( class, nin, nout, fwd, inv, options )
  char * class
  int nin
  int nout
  AV* fwd
  AV* inv
  char * options
 PREINIT:
  int nfwd;
  int ninv;
  SV** elem;
  int i;
  char ** cfwd;
  char ** cinv;
 CODE:
  nfwd = av_len( fwd ) + 1;
  ninv = av_len( inv ) + 1;
  cfwd = pack1Dchar( fwd );
  cinv = pack1Dchar( inv );
  RETVAL = astMathMap( nin, nout, nfwd, (const char **)cfwd, 
                       ninv, (const char**)cinv, options );
 OUTPUT:
  RETVAL

MODULE = Starlink::AST  PACKAGE = Starlink::AST::MatrixMap

# Note that form is derived from the size of matrix

AstMatrixMap *
new( class, nin, nout, matrix, options )
  char * class
  int nin
  int nout
  AV* matrix
  char * options
 PREINIT:
  int len;
  int form;
  double * cmatrix;
 CODE:
  len = av_len( matrix );
  /* determine form from number of elements */
  if (len == -1) {
    form = 2;
  } else if (len == nin || len == nout ) {
    form = 1;
  } else if ( len == (nin * nout ) ) {
    form = 0;
  } else {
    Perl_croak(aTHX_ "MatrixMap: matrix len not consistent with nout/nin");
  }
  cmatrix = pack1D(newRV_noinc((SV*)matrix), 'd');
  ASTCALL(
   RETVAL = astMatrixMap( nin, nout, form, cmatrix, options );
  )
 OUTPUT:
  RETVAL

MODULE = Starlink::AST   PACKAGE = Starlink::AST::Plot

AstPlot *
_new( class, frame, graphbox, basebox, options )
  char * class
  AstFrame * frame
  AV* graphbox
  AV* basebox
  char * options
 PREINIT:
  int len;
  float * cgraphbox;
  double * cbasebox;
 CODE:
  len = av_len( graphbox ) + 1;
  if ( len != 4 ) Perl_croak(aTHX_ "GraphBox must contain 4 values" );
  len = av_len( basebox ) + 1;
  if ( len != 4 ) Perl_croak(aTHX_ "BaseBox must contain 4 values" );
  cbasebox = pack1D( newRV_noinc((SV*)basebox), 'd');
  cgraphbox = pack1D( newRV_noinc((SV*)graphbox), 'f');
  ASTCALL(
    RETVAL = astPlot( frame, cgraphbox, cbasebox, options );
  )
 OUTPUT:
  RETVAL

MODULE = Starlink::AST   PACKAGE = Starlink::AST::PcdMap

AstPcdMap *
new( class, disco, pcdcen, options )
  char * class
  double disco
  AV* pcdcen
  char * options
 PREINIT:
  int len;
  double * cpcdcen;
 CODE:
  len = av_len( pcdcen );
  if (len != 1 ) {
    Perl_croak(aTHX_ "Must supply two values to PcdCen");
  }
  cpcdcen = pack1D(newRV_noinc((SV*)pcdcen), 'd');
  ASTCALL(
   RETVAL = astPcdMap( disco, cpcdcen, options );
  )
 OUTPUT:
  RETVAL

MODULE = Starlink::AST   PACKAGE = Starlink::AST::PermMap

AstPermMap *
new( class, inperm, outperm, constant, options )
  char * class
  AV* inperm
  AV* outperm
  AV* constant
  char * options
 PREINIT:
  int len;
  int * coutperm;
  int * cinperm;
  double * cconstant;
  int nin;
  int nout;
 CODE:
  nin = av_len( inperm );
  if (nin == -1 ) {
    /* no values */
    cinperm = NULL;
  } else {
    cinperm = pack1D(newRV_noinc((SV*)inperm), 'i' );
  }
  nout = av_len( outperm );
  if (nout == -1 ) {
    /* no values */
    coutperm = NULL;
  } else {
    coutperm = pack1D(newRV_noinc((SV*)outperm), 'i' );
  }
  len = av_len( constant );
  if (len == -1 ) {
    /* no values */
    cconstant = NULL;
  } else {
    cconstant = pack1D(newRV_noinc((SV*)constant), 'd' );
  }
  ASTCALL(
   RETVAL = astPermMap(nin, cinperm, nout, coutperm, cconstant, options );
  )
 OUTPUT:
  RETVAL

MODULE = Starlink::AST   PACKAGE = Starlink::AST::PolyMap

AstPolyMap *
new( class )
 CODE: 
#ifndef HASPOLYMAP  
   Perl_croak(aTHX_ "PolyMap: Please upgrade to AST V3.x or greater");
#else 
  Perl_croak(aTHX_ "PolyMap not yet implemented");
#endif

MODULE = Starlink::AST   PACKAGE = Starlink::AST::ShiftMap

AstShiftMap *
new( class, shift, options )
  char * class
  AV* shift
  char * options
 PREINIT:
  int ncoord;
  double * cshift;
 CODE:
#ifndef HASSHIFTMAP  
   Perl_croak(aTHX_ "ShiftMap: Please upgrade to AST V3.x or greater");
#else 
  ncoord = av_len( shift );
  cshift = pack1D(newRV_noinc((SV*)shift), 'd');
  ASTCALL(
   RETVAL = astShiftMap( ncoord, cshift, options);
  )
#endif
 OUTPUT:
  RETVAL

MODULE = Starlink::AST   PACKAGE = Starlink::AST::SkyFrame

AstSkyFrame *
new( class, options )
  char * class
  char * options
 CODE:
  ASTCALL(
   RETVAL = astSkyFrame( options );
  )
 OUTPUT:
  RETVAL

MODULE = Starlink::AST   PACKAGE = Starlink::AST::SpecFrame

AstSpecFrame *
new( class, options )
  char * class
  char * options
 CODE:
#ifndef HASSPECFRAME
   Perl_croak(aTHX_ "SpecFrame: Please upgrade to AST V2.x or greater");
#else
  ASTCALL(
   RETVAL = astSpecFrame( options );
  )
#endif
 OUTPUT:
  RETVAL


MODULE = Starlink::AST   PACKAGE = Starlink::AST::SlaMap

AstSlaMap *
new( class, flags, options )
  char * class
  int flags
  char * options
 CODE:
  ASTCALL(
   RETVAL = astSlaMap( flags, options );
  )
 OUTPUT:
  RETVAL

MODULE = Starlink::AST   PACKAGE = Starlink::AST::SphMap

AstSphMap *
new( class, options )
  char * class
  char * options
 CODE:
  ASTCALL(
   RETVAL = astSphMap( options );
  )
 OUTPUT:
  RETVAL

MODULE = Starlink::AST   PACKAGE = Starlink::AST::SpecMap

AstSpecMap *
new( class, nin, flags, options )
  char * class
  int nin
  int flags
  char * options
 CODE:
#ifndef HASSPECMAP
   Perl_croak(aTHX_ "SpecMap: Please upgrade to AST V2.x or greater");
#else
  ASTCALL(
   RETVAL = astSpecMap( nin, flags, options );
  )
#endif
 OUTPUT:
  RETVAL


MODULE = Starlink::AST   PACKAGE = Starlink::AST::TranMap

AstTranMap *
new( class, map1, map2, options )
  char * class
  AstMapping * map1
  AstMapping * map2
  char * options
 CODE:
#ifndef HASTRANMAP
   Perl_croak(aTHX_ "TranMap: Please upgrade to AST V3.2 or greater");
#else
  ASTCALL(
   RETVAL = astTranMap( map1, map2, options );
  )
#endif
 OUTPUT:
  RETVAL

MODULE = Starlink::AST   PACKAGE = Starlink::AST::UnitMap

AstUnitMap *
new( class, ncoord, options )
  char * class
  int ncoord
  char * options
 CODE:
  ASTCALL(
   RETVAL = astUnitMap( ncoord, options );
  )
 OUTPUT:
  RETVAL

MODULE = Starlink::AST   PACKAGE = Starlink::AST::WcsMap

AstWcsMap *
new( class, ncoord, type, lonax, latax, options )
  char * class
  int ncoord
  WcsMapType type
  int lonax
  int latax
  char * options
 CODE:
  ASTCALL(
   RETVAL = astWcsMap( ncoord, type, lonax, latax,options );
  )
 OUTPUT:
  RETVAL

MODULE = Starlink::AST   PACKAGE = Starlink::AST::WinMap

# we derive ncoord from the input array dimensions

AstWinMap *
new( class, ina, inb, outa, outb, options )
  char * class
  AV* ina
  AV* inb
  AV* outa
  AV* outb
  char * options
 CODE:
  /* minimal arg checking - lazy XXXX */
  RETVAL = astWinMap( av_len(ina)+1, pack1D(newRV_noinc((SV*)ina),'d'), 
                      pack1D(newRV_noinc((SV*)inb),'d'),
                      pack1D(newRV_noinc((SV*)outa),'d'),
                      pack1D(newRV_noinc((SV*)outb),'d'),options );
 OUTPUT:
  RETVAL

MODULE = Starlink::AST   PACKAGE = Starlink::AST::ZoomMap

AstZoomMap *
new( class, ncoord, zoom, options )
  char * class
  int ncoord
  double zoom
  char * options
 CODE:
  ASTCALL(
   RETVAL = astZoomMap( ncoord, zoom, options );
  )
 OUTPUT:
  RETVAL


MODULE = Starlink::AST   PACKAGE = Starlink::AST PREFIX = ast

void
astClear( this, attrib )
  AstObject * this
  char * attrib
 CODE:
  ASTCALL(
    astClear( this, attrib );
  )

# Store flag in the object when annulled so that the object destructor
# does not cause a second annul.

void
astAnnul( this )
  AstObject * this
 PREINIT:
  SV* arg = ST(0);
 CODE:
  ASTCALL(
   astAnnul( this );
  )
  setPerlObjectAttr( arg, "_annul",newSViv(1));


AstObject *
ast_Clone( this )
  AstObject * this
 CODE:
  ASTCALL(
   RETVAL = astClone( this );
  )
 OUTPUT:
  RETVAL

AstObject *
ast_Copy( this )
  AstObject * this
 CODE:
  ASTCALL(
   RETVAL = astCopy( this );
  )
 OUTPUT:
  RETVAL

void
astDelete( this )
  AstObject * this
 CODE:
  ASTCALL(
   astDelete( this );
  )

void
astExempt( this )
  AstObject * this
 CODE:
  ASTCALL(
   astExempt( this );
  )

void
astExport( this )
  AstObject * this
 CODE:
  ASTCALL(
   astExport( this );
  )

const char *
astGetC( this, attrib )
  AstObject * this
  char * attrib
 CODE:
  ASTCALL(
   RETVAL = astGetC( this, attrib );
  )
 OUTPUT:
  RETVAL

# Float is just an alias for double

double
astGetD( this, attrib )
  AstObject * this
  char * attrib
 ALIAS:
  astGetF = 1 
 CODE:
  ASTCALL(
   RETVAL = astGetD( this, attrib );
  )
 OUTPUT:
  RETVAL

int
astGetI( this, attrib )
  AstObject * this
  char * attrib
 ALIAS:
  astGetL = 1
 CODE:
  ASTCALL(
   RETVAL = astGetI( this, attrib );
  )
 OUTPUT:
  RETVAL

# Need to decide later whether the astIsA functions need to be
# implemented since Perl can do that - XXXX



# sprintf behaviour is left to the enclosing perl layer

void
ast_Set(this, settings )
  AstObject * this
  char * settings
 CODE:
  ASTCALL(
   astSet(this, settings );
  )

void
astSetC( this, attrib, value )
  AstObject * this
  char * attrib
  char * value
 CODE:
  ASTCALL(
   astSetC( this, attrib, value );
  )

# Float is just an alias for double

void
astSetD( this, attrib, value )
  AstObject * this
  char * attrib
  double value
 ALIAS:
  astSetF = 1 
 CODE:
  ASTCALL(
   astSetD( this, attrib, value );
  )


void
astSetI( this, attrib, value )
  AstObject * this
  char * attrib
  int value
 ALIAS:
  astSetL = 1
 CODE:
  ASTCALL(
   astSetI( this, attrib, value );
  )

void
astShow( this )
  AstObject * this
 CODE:
  ASTCALL(
   astShow( this );
  )

bool
astTest( this, attrib )
  AstObject * this
  char * attrib
 CODE:
  ASTCALL(
   RETVAL = astTest( this, attrib );
  )
 OUTPUT:
  RETVAL

# Use annul as automatic destructor
# For automatic destructor we do not want to throw an exception
# on error. So do not use ASTCALL. Do a manual printf to stderr and continue.

void
astDESTROY( obj )
  SV * obj
 PREINIT:
  int my_xsstatus_val = 0;
  int *my_xsstatus = &my_xsstatus_val;
  int *old_ast_status;
  int i;
  SV ** elem;
  SV * flag;
  char one[3] = "! ";
  char two[3] = "!!";
  char * pling;
  AV* local_err;
  char * s = CopFILE( PL_curcop );
  STRLEN msglen;
  IV mytmp;
  AstObject * this;
 CODE:
  /* see if we have annulled already */
  flag = getPerlObjectAttr( obj, "_annul");
  if (flag == NULL || ! SvTRUE(flag) ) {
    /* DESTROY always seems to insert stub code for SVREF not what is in  */
    /* the typemap file. Do it manually */
    mytmp = extractAstIntPointer( obj );
    this = INT2PTR( AstObject *, mytmp );

    MUTEX_LOCK(&AST_mutex);
    My_astClearErrMsg();
    old_ast_status = astWatch( my_xsstatus );
    astAnnul( this );
    astWatch( old_ast_status );
    My_astCopyErrMsg( &local_err );
    MUTEX_UNLOCK(&AST_mutex);
    if (*my_xsstatus != 0 ) {
      for (i=0; i <= av_len( local_err ); i++ ) {
        pling = ( i == 0 ? two : one );
        elem = av_fetch( local_err, i, 0 );
        if (elem != NULL ) {
          PerlIO_printf( PerlIO_stderr(),  "%s %s\n", pling,
		         SvPV( *elem, msglen ));
        }
      }
      if (!s) s = "(none)";
      PerlIO_printf( PerlIO_stderr(),  
                     "!  (in cleanup from file %s:%" IVdf ")\n",
                     s, (IV) CopLINE(PL_curcop));
    }
  }


MODULE = Starlink::AST   PACKAGE = Starlink::AST::Frame PREFIX = ast


double
astAngle( this, a, b, c )
  AstFrame * this
  AV* a
  AV* b
  AV* c
 PREINIT:
  double * aa;
  double * bb;
  double * cc;
  int naxes;
 CODE:
  /* Create C arrays of the correct dimensions */
  naxes = astGetI( this, "Naxes" );

  /* Copy from the perl array to the C array */
  if (av_len(a) != naxes-1)
     Perl_croak(aTHX_ "Number of elements in first coord array must be %d",
                naxes);
  if (av_len(b) != naxes-1)
     Perl_croak(aTHX_ "Number of elements in second coord array must be %d",
                naxes);
  if (av_len(c) != naxes-1)
     Perl_croak(aTHX_ "Number of elements in third coord array must be %d",
                naxes);

  aa = pack1D( newRV_noinc((SV*)a), 'd');
  bb = pack1D( newRV_noinc((SV*)b), 'd');
  cc = pack1D( newRV_noinc((SV*)c), 'd');

  /* Call the ast function */
  ASTCALL(
   RETVAL = astAngle( this, aa, bb, cc);
  )
 OUTPUT:
  RETVAL

double
astAxAngle( this, a, b, axis )
  AstFrame * this
  AV* a
  AV* b
  int axis
 PREINIT:
  double * aa;
  double * bb;
  int naxes;
 CODE:
  /* Create C arrays of the correct dimensions */
  naxes = astGetI( this, "Naxes" );

  /* Copy from the perl array to the C array */
  if (av_len(a) != naxes-1)
     Perl_croak(aTHX_ "Number of elements in first coord array must be %d",
                naxes);
  if (av_len(b) != naxes-1)
     Perl_croak(aTHX_ "Number of elements in second coord array must be %d",
                naxes);

  aa = pack1D( newRV_noinc((SV*)a), 'd');
  bb = pack1D( newRV_noinc((SV*)b), 'd');
  ASTCALL(
   RETVAL = astAxAngle( this, aa, bb, axis);
  )
 OUTPUT:
  RETVAL

double
astAxDistance( this, axis, v1, v2)
  AstFrame * this
  int axis
  double v1
  double v2
 CODE:
  ASTCALL(
   RETVAL = astAxDistance( this, axis, v1, v2);
  )
 OUTPUT:
  RETVAL

double
astAxOffset( this, axis, v1, dist)
  AstFrame * this
  int axis
  double v1
  double dist
 CODE:
  ASTCALL(
   RETVAL = astAxOffset( this, axis, v1, dist);
  )
 OUTPUT:
  RETVAL

AstFrameSet *
astConvert( from, to, domainlist )
  AstFrame * from
  AstFrame * to
  char * domainlist
 CODE:
  ASTCALL(
   RETVAL = astConvert( from, to, domainlist );
  )
 OUTPUT:
  RETVAL

double
astDistance( this, point1, point2 )
  AstFrame * this
  AV* point1
  AV* point2
 PREINIT:
  double * aa;
  double * bb;
  int naxes;
 CODE:
  /* Create C arrays of the correct dimensions */
  naxes = astGetI( this, "Naxes" );

  /* Copy from the perl array to the C array */
  if (av_len(point1) != naxes-1)
     Perl_croak(aTHX_ "Number of elements in first coord array must be %d",
                naxes);
  if (av_len(point2) != naxes-1)
     Perl_croak(aTHX_ "Number of elements in second coord array must be %d",
                naxes);

  aa = pack1D( newRV_noinc((SV*)point1), 'd');
  bb = pack1D( newRV_noinc((SV*)point2), 'd');
  ASTCALL(
   RETVAL = astDistance( this, aa, bb);
  )
 OUTPUT:
  RETVAL

AstFrameSet *
astFindFrame( this, template, domainlist )
  AstFrame * this
  AstFrame * template
  char * domainlist
 CODE:
  ASTCALL(
   RETVAL = astFindFrame( this, template, domainlist );
  )
 OUTPUT:
  RETVAL

const char *
astFormat( this, axis, value )
  AstFrame * this
  int axis
  double value
 CODE:
  ASTCALL(
   RETVAL = astFormat( this, axis, value );
  )
 OUTPUT:
  RETVAL

int
astGetActiveUnit( this )
  AstFrame * this
 CODE:
#ifndef HASGETACTIVEUNIT
  Perl_croak(aTHX_ "astGetActiveUnit: Please upgrade to AST V2.x or newer");
#else
  ASTCALL(
   RETVAL = astGetActiveUnit( this );
  )
#endif
 OUTPUT:
  RETVAL

void
astNorm( this, value )
  AstFrame * this
  AV* value
 PREINIT:
  int naxes;
  double * aa;
 CODE:
  /* Create C arrays of the correct dimensions */
  naxes = astGetI( this, "Naxes" );

  /* Copy from the perl array to the C array */
  if (av_len(value) != naxes-1)
     Perl_croak(aTHX_ "Number of elements in first coord array must be %d",
                naxes);
  aa = pack1D( newRV_noinc((SV*)value), 'd');
  ASTCALL(
   astNorm( this, aa );
  )

# Return list

void
astOffset( this, point1, point2, offset )
  AstFrame * this
  AV* point1
  AV* point2
  double offset
 PREINIT:
  int naxes;
  double * aa;
  double * bb;
  double * point3;
  int i;
  AV * myoffset;
 PPCODE:
  naxes = astGetI( this, "Naxes" );

  /* Copy from the perl array to the C array */
  if (av_len(point1) != naxes-1)
     Perl_croak(aTHX_ "Number of elements in first coord array must be %d",
                naxes);
  aa = pack1D( newRV_noinc((SV*)point1), 'd');
  if (av_len(point2) != naxes-1)
     Perl_croak(aTHX_ "Number of elements in second coord array must be %d",
                naxes);
  bb = pack1D( newRV_noinc((SV*)point2), 'd');


  /* Somewhere to put the return values */
  point3 = get_mortalspace( naxes, 'd' );

  ASTCALL(
   astOffset( this, aa, bb, offset, point3 );
  )

  /* now need to push the resulting values onto the return stack */
  /* Put everything in an array [rather than the stack] in order to
     be consistent in returning C arrays as perl arrays. */
  myoffset = newAV();
  for (i =0; i < naxes; i++ ) {
    av_push( myoffset, newSVnv( point3[i] ));
  }
  XPUSHs( newRV_noinc( (SV*)myoffset ));



# Returns angle and reference to array of pair of coordinates

void
astOffset2( this, point1, angle, offset )
  AstFrame * this
  AV* point1
  double angle
  double offset
 PREINIT:
  int naxes;
  double * aa;
  double * point2;
  int i;
  double RETVAL;
  AV * myoffset;
 PPCODE:
  naxes = astGetI( this, "Naxes" );

  /* Copy from the perl array to the C array */
  if (av_len(point1) != naxes-1)
     Perl_croak(aTHX_ "Number of elements in first coord array must be %d",
                naxes);
  aa = pack1D( newRV_noinc((SV*)point1), 'd');

  /* Somewhere to put the return values */
  point2 = get_mortalspace( naxes, 'd' );

  ASTCALL(
   RETVAL = astOffset2( this, aa, angle, offset, point2 );
  )

  /* Push the angle on to the stack */
  XPUSHs(sv_2mortal(newSVnv(RETVAL)));

  /* Put everything in an array [rather than the stack] in order to
     be consistent in returning C arrays as perl arrays. */
  myoffset = newAV();
  for (i =0; i < naxes; i++ ) {
    av_push( myoffset, newSVnv( point2[i] ));
  }
  XPUSHs( newRV_noinc( (SV*)myoffset ));


void
astPermAxes( this, perm )
  AstFrame * this
  AV* perm
 PREINIT:
  int * aa;
  int naxes;
 CODE:
  naxes = astGetI(this, "Naxes");
  /* Copy from the perl array to the C array */
  if (av_len(perm) != naxes-1)
     Perl_croak(aTHX_ "Number of elements in perm array must be %d",
                naxes);
  aa = pack1D( newRV_noinc((SV*)perm), 'i');
  ASTCALL(
   astPermAxes( this, aa );
  )

# Returns a new frame and an optional mapping
# Use a boolean to control whether a mapping is returned
# Ignore for now

# Also note that we count axes ourselfs

AstFrame *
astPickAxes( this, axes )
  AstFrame * this;
  AV* axes
 PREINIT:
  int maxaxes;
  int naxes;
  int * aa;
 CODE:
  maxaxes = astGetI(this, "Naxes");
  naxes = av_len(axes) + 1;
  if ( naxes > maxaxes )
    Perl_croak(aTHX_ "Number of axes selected must be less than number of axes in frame");
  aa = pack1D( newRV_noinc((SV*)axes), 'i');
  ASTCALL(
   RETVAL = astPickAxes( this, naxes, aa, NULL);
  )
 OUTPUT:
  RETVAL

# Returns reference to array [point4], plus two distances

void
astResolve( this, point1, point2, point3 )
  AstFrame * this
  AV* point1
  AV* point2
  AV* point3
 PREINIT:
  double * cpoint1;
  double * cpoint2;
  double * cpoint3;
  double * cpoint4;
  AV * point4;
  double d1;
  double d2;
  int len;
  int naxes;
 PPCODE:
  naxes = astGetI(this, "Naxes");
  len = av_len(point1) + 1;
  if ( naxes != len )
    Perl_croak(aTHX_ "Number of coords in point1 must be equal to the number of axes in frame [%d != %d]", naxes, len);
  len = av_len(point2) + 1;
  if ( naxes != len )
    Perl_croak(aTHX_ "Number of coords in point2 must be equal to the number of axes in frame [%d != %d]", naxes, len);
  len = av_len(point3) + 1;
  if ( naxes != len )
    Perl_croak(aTHX_ "Number of coords in point3 must be equal to the number of axes in frame [%d != %d]", naxes, len);

  cpoint1 = pack1D( newRV_noinc((SV*)point1), 'd');
  cpoint2 = pack1D( newRV_noinc((SV*)point2), 'd');
  cpoint3 = pack1D( newRV_noinc((SV*)point3), 'd');
  cpoint4 = get_mortalspace( naxes, 'd' );
  
  ASTCALL(
    astResolve(this, cpoint1, cpoint2, cpoint3, cpoint4, &d1, &d2);
  )

  point4 = newAV();
  unpack1D( newRV_noinc((SV*)point4), cpoint4, 'd', naxes);

  XPUSHs( newRV_noinc((SV*) point4));
  XPUSHs( sv_2mortal(newSVnv(d1)));
  XPUSHs( sv_2mortal(newSVnv(d2)));




void
astSetActiveUnit( this, value )
  AstFrame * this
  int value
 CODE:
#ifndef HASSETACTIVEUNIT
  Perl_croak(aTHX_ "astSetActiveUnit: Please upgrade to AST V2.x or newer");
#else
  ASTCALL(
   astSetActiveUnit( this, value );
  )
#endif

# astUnformat currently returns the value not the number of
# characters read. Returns undef if no character read
#  XXXXX

double
astUnformat( this, axis, string )
  AstFrame * this
  int axis
  char * string
 PREINIT:
  int nread;
 CODE:
  nread = astUnformat( this, axis, string, &RETVAL );
  if (nread == 0 ) XSRETURN_UNDEF;
 OUTPUT:
  RETVAL


MODULE = Starlink::AST   PACKAGE = Starlink::AST::FrameSet PREFIX = ast

void
astAddFrame( this, iframe, map, frame)
  AstFrameSet * this
  int iframe
  AstMapping * map
  AstFrame * frame
 CODE:
  ASTCALL(
   astAddFrame( this, iframe, map, frame );
  )


AstFrame *
astGetFrame( this, iframe )
  AstFrameSet * this
  int iframe
 CODE:
  ASTCALL(
   RETVAL = astGetFrame( this, iframe );
  )
 OUTPUT:
  RETVAL

AstMapping *
astGetMapping( this, iframe1, iframe2 )
  AstFrameSet * this
  int iframe1
  int iframe2
 CODE:
  ASTCALL(
   RETVAL = astGetMapping( this, iframe1, iframe2 );
  )
 OUTPUT:
  RETVAL

void
astRemapFrame( this, iframe, map )
  AstFrameSet * this
  int iframe
  AstMapping * map
 CODE:
  ASTCALL(
   astRemapFrame( this, iframe, map );
  )

void
astRemoveFrame( this, iframe )
  AstFrameSet * this
  int iframe
 CODE:
  ASTCALL(
   astRemoveFrame( this, iframe );
  )

MODULE = Starlink::AST   PACKAGE = Starlink::AST::Mapping PREFIX = ast

# Return the new mappings and booleans as a list
# Do this later since it requires subversion of the typemap
# system

# XXXXX

void
astDecompose( this )
  AstMapping * this
 PREINIT:
  AstMapping * map1;
  AstMapping * map2;
  int series;
  int invert1;
  int invert2;
 PPCODE:
  Perl_croak(aTHX_ "astDecompose not yet implemented\n");
  /* May want to restrict this to CmpMap and CmpFrame classes
     explicitly */
  ASTCALL(
   astDecompose(this, &map1, &map2, &series, &invert1, &invert2);
  )


void
astInvert( this )
  AstMapping * this
 CODE:
  ASTCALL(
   astInvert( this );
  )

# astMapBox  XXXX


# astRate
#  Returns the rate and ref to array of derivatives
#  Returns empty list if astRate returns AST__BAD

void
astRate( this, at, ax1, ax2 )
  AstMapping * this
  AV* at
  int ax1
  int ax2
 PREINIT:
  int nin;
  int len;
  double * cat;
  double RETVAL;
  double d2;
 PPCODE:
#ifndef HASRATE
   Perl_croak(aTHX_ "astRate: Please upgrade to AST V3.x or greater");
#else
  nin = astGetI( this, "Nin");
  len = av_len( at ) + 1;
  if (nin != len)
      Perl_croak(aTHX_ "Must supply Nin coordinates to astRate [%d != %d]",
                        nin, len);
  cat = pack1D( newRV_noinc((SV*)at), 'd');

  ASTCALL(
    RETVAL = astRate( this, cat, ax1, ax2, &d2 );
  )
  if ( RETVAL != AST__BAD ) {
     XPUSHs(sv_2mortal(newSVnv(RETVAL)));
     XPUSHs(sv_2mortal(newSVnv(d2)));
  } else {
     XSRETURN_EMPTY;
  }
#endif


# astResample XXXX


AstMapping *
astSimplify( this )
  AstMapping * this
 CODE:
  ASTCALL(
   RETVAL = astSimplify( this );
  )
 OUTPUT:
  RETVAL

# astTran1
#   Returns one array
# Even though we return one array, we use PPCODE so that it is closer to
# the code used for astTran2

void
astTran1( this, xin, forward )
  AstMapping * this
  AV* xin
  bool forward
 PREINIT:
  int len1;
  double * cxin;
  AV* xout;
  double * cxout;
  SV** elem;
 PPCODE:
  len1 = av_len( xin ) + 1;
  cxin = pack1D( newRV_noinc((SV*)xin), 'd');
  cxout = get_mortalspace( len1, 'd' );

  ASTCALL(
    astTran1( this, len1, cxin, forward, cxout );
  )

  xout = newAV();
  unpack1D( newRV_noinc((SV*) xout), cxout, 'd', len1);

  XPUSHs( newRV_noinc((SV*) xout ));



# astTran2
#   Returns 2 arrays

void
astTran2( this, xin, yin, forward )
  AstMapping * this
  AV* xin
  AV* yin
  bool forward
 PREINIT:
  int len1;
  int len2;
  double * cxin;
  double * cyin;
  AV* xout;
  AV* yout;
  double * cxout;
  double * cyout;
  SV** elem;
 PPCODE:
  len1 = av_len( xin ) + 1;
  len2 = av_len( yin ) + 1;
  if ( len1 != len2 )
     Perl_croak(aTHX_ "Number of elements in input arrays must be identical (%d != %d )",
             len1, len2);
  cxin = pack1D( newRV_noinc((SV*)xin), 'd');
  cyin = pack1D( newRV_noinc((SV*)yin), 'd');
  cxout = get_mortalspace( len1, 'd' );
  cyout = get_mortalspace( len2, 'd' );

  ASTCALL(
    astTran2( this, len1, cxin, cyin, forward, cxout, cyout );
  )

  xout = newAV();
  yout = newAV();
  unpack1D( newRV_noinc((SV*) xout), cxout, 'd', len1);
  unpack1D( newRV_noinc((SV*) yout), cyout, 'd', len2);

  XPUSHs( newRV_noinc((SV*) xout ));
  XPUSHs( newRV_noinc((SV*) yout ));



# astTranN  XXXX

# astTranP  XXXX



MODULE = Starlink::AST   PACKAGE = Starlink::AST::Channel PREFIX = ast

AstObject *
ast_Read( channel )
  AstChannel * channel
 CODE:
  ASTCALL(
   RETVAL = astRead( channel );
  )
 OUTPUT:
  RETVAL

int
astWrite( channel, object )
  AstChannel * channel
  AstObject * object
 CODE:
  ASTCALL(
   RETVAL = astWrite( channel, object );
  )
 OUTPUT:
  RETVAL

MODULE = Starlink::AST   PACKAGE = Starlink::AST::FitsChan PREFIX = ast

void
astPutFits( this, card, overwrite )
  AstFitsChan * this
  char * card
  int overwrite
 CODE:
  ASTCALL(
   astPutFits(this, card, overwrite);
  )

void
astDelFits( this )
  AstFitsChan * this
 CODE:
  ASTCALL(
   astDelFits( this );
  )

# Need to handle a NULL card  - XXXXX

int
astFindFits( this, name, card, inc )
  AstFitsChan * this
  char * name
  char * card = NO_INIT
  int inc
 PREINIT:
  char buff[81];
 CODE:
  card = buff;
  ASTCALL(
   RETVAL = astFindFits( this, name, card, inc );
  )
 OUTPUT:
  RETVAL 
  card

MODULE = Starlink::AST   PACKAGE = Starlink::AST::SpecFrame PREFIX = ast

void
astSetRefPos( this, frm, lon, lat)
  AstSpecFrame * this
  AstSkyFrame * frm
  double lon
  double lat
 CODE:
#ifndef HASSETREFPOS
  Perl_croak(aTHX_ "astSetRefPos: Please upgrade to AST v2.x or newer");
#else
  ASTCALL(
   astSetRefPos( this, frm, lon, lat );
  )
#endif

# XXX frm is allowed to be null here

void
astGetRefPos( this, frm )
  AstSpecFrame * this
  AstSkyFrame * frm
 PREINIT:
  double lon;
  double lat;
 PPCODE:
#ifndef HASGETREFPOS
  Perl_croak(aTHX_ "astGetRefPos: Please upgrade to AST v2.x or newer");
#else
  ASTCALL(
   astGetRefPos( this, frm, &lon, &lat );
  )
  XPUSHs(sv_2mortal(newSVnv(lon)));
  XPUSHs(sv_2mortal(newSVnv(lat)));
#endif 

MODULE = Starlink::AST   PACKAGE = Starlink::AST::SlaMap PREFIX = astSla

void
astSlaAdd( this, cvt, args )
  AstSlaMap * this
  char * cvt
  AV* args
 PREINIT:
  double * cargs;
 CODE:
  cargs = pack1D(newRV_noinc((SV*)args), 'd');
  ASTCALL(
   astSlaAdd( this, cvt, cargs );
  )

MODULE = Starlink::AST   PACKAGE = Starlink::AST::SpecMap PREFIX = astSpec

void
astSpecAdd( this, cvt, args )
  AstSpecMap * this
  char * cvt
  AV* args
 PREINIT:
  double * cargs;
 CODE:
  cargs = pack1D(newRV_noinc((SV*)args), 'd');
#ifndef HASSPECADD
  Perl_croak(aTHX_ "astSpecAdd: Please upgrade to AST v2.x or newer");
#else
  ASTCALL(
   astSpecAdd( this, cvt, cargs );
  )
#endif

MODULE = Starlink::AST   PACKAGE = Starlink::AST::Plot  PREFIX = ast

void
astBorder( this )
  AstPlot * this
 PREINIT:
  SV* arg = ST(0);
 CODE:
  PLOTCALL(arg,
	   astBorder(this);
  )

void
astBoundingBox( this )
  AstPlot * this
 PREINIT:
  float clbnd[2];
  float cubnd[2];
  AV* lbnd;
  AV* ubnd;
  SV * arg = ST(0);
 PPCODE:
  PLOTCALL (arg,
   astBoundingBox( this, clbnd, cubnd );
  )
  lbnd = newAV();
  unpack1D( newRV_noinc((SV*) lbnd), clbnd, 'f', 2 );
  ubnd = newAV();
  unpack1D( newRV_noinc((SV*) ubnd), cubnd, 'f', 2 );
  XPUSHs(newRV_noinc((SV*)lbnd ));
  XPUSHs(newRV_noinc((SV*)ubnd ));


void
astClip( this, iframe, lbnd, ubnd )
  AstPlot * this
  int iframe
  AV* lbnd
  AV* ubnd
 PREINIT:
  int len;
  double * clbnd;
  double * cubnd;
  int naxes;
  SV * arg = ST(0);
 CODE:
  naxes = astGetI( this, "Naxes" );
  len = av_len( lbnd ) + 1;
  if ( len != naxes ) Perl_croak( aTHX_ "lbnd must contain %d elements", naxes );
  len = av_len( ubnd ) + 1;
  if ( len != naxes ) Perl_croak( aTHX_ "ubnd must contain %d elements", naxes );
  clbnd = pack1D(newRV_noinc((SV*)lbnd), 'd');
  cubnd = pack1D(newRV_noinc((SV*)ubnd), 'd');
  PLOTCALL (arg,
   astClip( this, iframe, clbnd, cubnd );
  )

void
astCurve( this, start, finish )
  AstPlot * this
  AV* start
  AV* finish
 PREINIT:
  int len;
  double * cstart;
  double * cfinish;
  int naxes;
  SV* arg = ST(0);
 CODE:
  naxes = astGetI(this, "Naxes" );
  len = av_len( start ) + 1;
  if ( len != naxes ) Perl_croak( aTHX_ "start must contain %d elements", naxes );
  len = av_len( finish ) + 1;
  if ( len != naxes ) Perl_croak( aTHX_ "finish must contain %d elements", naxes);
  cstart = pack1D(newRV_noinc((SV*)start), 'd');
  cfinish = pack1D(newRV_noinc((SV*)finish), 'd');
  PLOTCALL (arg,
   astCurve( this, cstart, cfinish );
  )

void
astGenCurve( this, map )
  AstPlot * this
  AstMapping * map
 PREINIT:
  SV * arg = ST(0);
 CODE:
  PLOTCALL(arg,
   astGenCurve(this, map);
  )

void
astGrid( this )
  AstPlot * this
 PREINIT:
  SV * arg = ST(0);
 CODE:
  PLOTCALL(arg,
   astGrid(this);
  )

void
astGridLine( this, axis, start, length )
  AstPlot * this
  int axis
  AV* start
  double length
 PREINIT:
  double * cstart;
  int naxes;
  int len;
  SV * arg = ST(0);
 CODE:
  naxes = astGetI( this, "Naxes" );
  len = av_len( start ) + 1;
  if ( len != naxes ) Perl_croak( aTHX_ "start must contain %d elements", naxes );
  cstart = pack1D(newRV_noinc((SV*)start), 'd');
  PLOTCALL(arg,
    astGridLine( this, axis, cstart, length );
  )

# Make this a little different to the published interface
# By requesting @x and @y rather than an array of coordinate doublets.

void
astMark(this, type, ...)
  AstPlot * this
  int type
 PREINIT:
  double * cin;
  int ncoords;
  int nmarks;
  int indim;
  int size;
  int i;
  int total;
  int argoff = 2; /* number of fixed arguments */
  int naxes;
  SV * arg = ST(0);
 CODE:
  /* First make sure we have some arguments */
    if (items > argoff ) {
    /* Number of dimensions should be just the number of stack items */
    ncoords = items - argoff;

    /* and this should equal the number of axes in the frame */
    naxes = astGetI( this, "Naxes" );

    if ( naxes != ncoords )     
         Perl_croak(aTHX_ "Number of supplied coordinate sets must equal number of axes in frame [%d != %d]",naxes,ncoords);

    /* Now go through each finding out how long each array is */
    for (i = argoff + 1; i<=items; i++ ) {
        int nelem;
        int index = i - 1;
        SV * coordsv = ST(index);
        AV * curr;
        if (SvROK(coordsv) && SvTYPE(SvRV(coordsv)) == SVt_PVAV) {
          curr = (AV*)SvRV( coordsv );
          nelem = av_len( curr ) + 1;
          if (i == argoff + 1) {
            /* No previous values */
            nmarks = nelem;
          } else if (nmarks != nelem) {
            Perl_croak(aTHX_ "All coordinates must have same number of elements [%d != %d]",nmarks, nelem);
          }
        } else {
          Perl_croak(aTHX_ "Argument %d to Mark() must be ref to array",i);
        }
    }

    /* Get some memory for the array */
    total = nmarks * ncoords;
    cin = get_mortalspace( total, 'd');    

    /* and go through the arrays again (but less checking now) */
    for (i = 0; i < ncoords; i++ ) {
        int j;
        int argpos = i + argoff;
        AV * curr = (AV*)SvRV( ST(argpos) );

        for (j = 0; j < nmarks ; j ++ ) {
          SV ** elem = av_fetch( curr, j, 0);
          double dtmp;
          if (elem == NULL ) {
             /* undef */
             dtmp = 0.0;
          } else {
             dtmp = SvNV( *elem );
          }
          /* use pointer arithmetic to make sure that things align
             the way AST expects */
          *(cin + (i * nmarks) + j) = dtmp;
        }
    }
    
    /* Now call the AST routine */
    PLOTCALL( arg,
       astMark( this, nmarks, ncoords, nmarks, cin, type );
    )

  } else {
    XSRETURN_EMPTY;
  }

# Make this a little different to the published interface
# By requesting @x and @y rather than an array of coordinate doublets.
# [code identical to astMark without the type]

void
astPolyCurve(this, ...)
  AstPlot * this
 PREINIT:
  double * cin;
  int ncoords;
  int npoints;
  int indim;
  int size;
  int i;
  int total;
  int argoff = 1; /* number of fixed arguments */
  int naxes;
  SV * arg = ST(0);
 CODE:
  /* First make sure we have some arguments */
  if (items > argoff ) {
    /* Number of dimensions should be just the number of stack items */
    ncoords = items - argoff;

    /* and this should equal the number of axes in the frame */
    naxes = astGetI( this, "Naxes" );

    if ( naxes != ncoords )     
         Perl_croak(aTHX_ "Number of supplied coordinate sets must equal number of axes in frame [%d != %d]",naxes,ncoords);

    /* Now go through each finding out how long each array is */
    for (i = argoff + 1; i<=items; i++ ) {
        int nelem;
        int index = i - 1;
        SV * coordsv = ST(index);
        AV * curr;
        if (SvROK(coordsv) && SvTYPE(SvRV(coordsv)) == SVt_PVAV) {
          curr = (AV*)SvRV( coordsv );
          nelem = av_len( curr ) + 1;
          if (i == argoff + 1) {
            /* No previous values */
            npoints = nelem;
          } else if (npoints != nelem) {
            Perl_croak(aTHX_ "All coordinates must have same number of elements [%d != %d]",npoints, nelem);
          }
        } else {
          Perl_croak(aTHX_ "Argument %d to Mark() must be ref to array",i);
        }
    }

    /* Get some memory for the array */
    total = npoints * ncoords;
    cin = get_mortalspace( total, 'd');    

    /* and go through the arrays again (but less checking now) */
    for (i = 0; i < ncoords; i++ ) {
        int j;
        int argpos = i + argoff;
        AV * curr = (AV*)SvRV( ST(argpos) );

        for (j = 0; j < npoints ; j ++ ) {
          SV ** elem = av_fetch( curr, j, 0);
          double dtmp;
          if (elem == NULL ) {
             /* undef */
             dtmp = 0.0;
          } else {
             dtmp = SvNV( *elem );
          }
          /* use pointer arithmetic to make sure that things align
             the way AST expects */
          *(cin + (i * npoints) + j) = dtmp;
        }
    }
    
    /* Now call the AST routine */
    PLOTCALL( arg,
       astPolyCurve( this, npoints, ncoords, npoints, cin );
    )

  } else {
    XSRETURN_EMPTY;
  }

void
astText( this, text, pos, up, just )
  AstPlot * this
  char * text
  AV* pos
  AV* up
  char * just
 PREINIT:
  int len;
  float * cup;
  double * cpos;
  int naxes;
  SV * arg = ST(0);
 CODE:
  naxes = astGetI( this, "Naxes" );
  len = av_len( pos ) + 1;
  if ( len != naxes ) Perl_croak( aTHX_ "pos must contain %d elements", naxes);
  len = av_len( up ) + 1;
  if ( len != 2 ) Perl_croak( aTHX_ "up must contain 2 elements");
  cpos = pack1D(newRV_noinc((SV*)pos), 'd');
  cup = pack1D(newRV_noinc((SV*)up), 'f');
  PLOTCALL(arg,
    astText( this, text, cpos, cup, just );
  )


# Constants

# Start with errors. Bless them into class Starlink::AST::Status

INCLUDE: AST_ERR.xsh

# Then the WcsMap constants

INCLUDE: AST_WCSMAP.xsh

# Then the Grf constants

INCLUDE: AST_GRF.xsh