
### GenomeCanvas::GD_StepMap

package GenomeCanvas::GD_StepMap;

use strict;
use Carp;
use GD;
use GenomeCanvas::FadeMap;
use MIME::Base64 'encode_base64';

sub new {
    my $pkg = shift;
    my $self = bless {
        _values     => [],
        _dimensions => [],
        }, $pkg;
    $self->dimensions(@_);
    return $self;
}

sub dimensions {
    my( $self, @dimensions ) = @_;
    
    if (@dimensions) {
        confess "Wrong number of arguments (@dimensions)"
            unless @dimensions == 2;
        foreach (@dimensions) {
            confess "Invalid parameters (@dimensions)"
                unless /^\d+$/;
        }
        $self->{'_dimensions'} = [@dimensions];
    }
    return @{$self->{'_dimensions'}};
}

sub color {
    my( $self, $color ) = @_;
    
    if ($color) {
        confess "Invalid color '$color'"
            unless $color =~ /^#[0-9a-fA-F]{6}/;
        return $self->{'_color'} = $color;
    }
    return $self->{'_color'} || '#000000';
}

sub range {
    my( $self, @range ) = @_;
    
    if (@range) {
        unless (@range == 2 and $range[0] < $range[1]) {
            confess "Invalid range [@range]";
        }
        $self->{'_range'} = [@range];
    }
    if (my $r = $self->{'_range'}) {
        @{$self->{'_range'}};
    } else {
        return (0,1);
    }
}

sub add_value {
    my( $self, $value ) = @_;
    
    confess "No value given" unless defined $value;
    
    push(@{$self->{'_values'}}, $value);
}

sub values {
    my( $self, @values ) = @_;
    
    if (@values) {
        $self->{'_values'} = [@values];
    }
    return @{$self->{'_values'}};
}

sub gif {
    my( $self ) = @_;
    
    # Make a graduated color scale
    my $color = $self->color;
    my $fader = GenomeCanvas::FadeMap->new;
    $fader->fade_color($color);
    
    # Make a GIF image object
    my ($x,$y) = $self->dimensions;
    confess "Missing dimensions (x='$x', y='$y')"
        unless $x and $y;
    warn "x='$x', y='$y'\n";
    my $img = GD::Image->new($x,$y);
    
    # Allocate colors in the image
    my @rgb_scale = $fader->rgb_scale;
    my( $prev );
    foreach my $rgb (@rgb_scale) {
        my $i = $img->colorAllocate(@$rgb);
        confess "Can't allocate color (@$rgb)" if $i == -1;
        if (defined $prev) {
            confess "color allocation out of sequence ($prev -> $i)"
                unless $i == ($prev + 1);
        }
        $prev = $i;
    }
    
    # Get the data to be plotted on the image
    my @values = $self->values;
    confess "Number of values '", scalar(@values), "' doesn't match image length '$y'"
        unless $x == @values;
    
    # Plot the data
    my ($min, $max) = $self->range;
    my $range = $max - $min;
    my $y_max = $y - 1;
    for (my $i = 0; $i < $x; $i++) {
        my $v = $values[$i];
        my $color_i = int((($v - $min) / $range) * @rgb_scale);
        $color_i-- if $color_i == @rgb_scale;
        $img->filledRectangle($i,0,$i,$y_max, $color_i);
    }
    
    return $img->gif;
}

# To pass to the Canvas's "-data" parameter, the
# gif image has to be base64 encoded.

sub base64_gif {
    my( $self ) = @_;
    
    return encode_base64($self->gif);
}

1;

__END__

=head1 NAME - GenomeCanvas::GD_StepMap

=head1 AUTHOR

James Gilbert B<email> jgrg@sanger.ac.uk

