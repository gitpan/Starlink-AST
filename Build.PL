use strict;
use warnings;
use File::Spec;
use Module::Build;
use Config;

# On OSX we need to restrict the exported symbols in the bundle
# to prevent NDF linking against libast clashing with NDF loading
# Starlink::AST
my $linkflags = "";
if ($^O eq 'darwin') {
  $linkflags = "-exported_symbols_list exported_symbols.lis";
}

my $file = File::Spec->catfile( "lib", "Starlink", "AST.pm" );

my $build = Module::Build->new
  (
   module_name => "Starlink::AST",
   abstract_from => $file,
   license => "gpl",
   author => [
              'Tim Jenness <tjenness@cpan.org>',
             ],
   version_from => $file,
   meta_merge => {
               resources =>  {
                              repository => "git://starlink.jach.hawaii.edu/perl-Starlink-AST.git",
                             },
                },
   recommends => {
                  "Tk" => 0,
                  "Tk::Zinc" => 0,
                  "Astro::FITS::CFITSIO" => 0,
                  "Astro::FITS::Header" => 0,
                 },
   build_requires => {
                      "Test::More" => 0,
                     },
   configure_requires => {
                          "Module::Build" => 0.3604,
                         },
   c_source => [ "src", "ast" ],
   extra_compiler_flags => [ "-Iextsrc", # we do not build these directly
                             "-DHAVE_DECL_ISNAN=1", # Assume we have NaN
                             "-DSIZEOF_LONG=". $Config{longsize},
                             "-DSIZEOF_LONG_LONG=". $Config{longlongsize},
                           ],
   extra_linker_flags => $linkflags,
  );

$build->create_build_script;
