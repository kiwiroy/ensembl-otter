
### KaryotypeWindow::Band::Stalk

package KaryotypeWindow::Band::Stalk;

use strict;
use Carp;
use base 'KaryotypeWindow::Band';


sub is_rectangular { return 0 };

sub draw {
    my( $self, $chr, $canvas, $x, $y ) = @_;
    
    warn "drawing a stalk";
    
    my $scale = $self->Mb_per_pixel;
    my $width = $chr->width;
    my $height = $self->height;
    my $name = $self->name;

    $self->set_stalk_coords($x, $y, $width, $height);
    
    $canvas->createPolygon(
        $self->top_coordinates,
        $self->bottom_coordinates,
        -outline    => $self->outline || undef,
        -fill       => $self->fill    || undef,
        -smooth     => 1,
        );
}

sub set_stalk_coords {
    my( $self, $x, $y, $width, $height ) = @_;
    
    $self->set_top_coordinates(
        $x+(0.4*$width), $y+(0.5*$height),
        $x,$y, $x,$y, $x+$width,$y, $x+$width,$y,
        $x+(0.6*$width), $y+(0.5*$height),
        );
    $self->set_bottom_coordinates(
        $x+$width,$y+$height, $x+$width,$y+$height,
        $x,$y+$height, $x,$y+$height,
        );
}


1;

__END__

=head1 NAME - KaryotypeWindow::Band::Stalk

=head1 AUTHOR

James Gilbert B<email> jgrg@sanger.ac.uk

