//
//  BLP.m
//  BLP
//
//  Created by Saladfork on 8/24/15.
//  Copyright (c) 2015 Saladfork. All rights reserved.
//

#import "BLP.h"

@implementation BLP

/**
 *  Initializes a new instance given a buffer of BLP data.
 */
-(id)initWithData:(NSData *)data error:(NSError **)error {
    self = [super init];
    if (self) {
        _data = data;
        if (![self parse:error]) {
            return nil;
        }
    }
    return self;
}

/**
 *  Convenience initializer
 */
-(id)initWithContentsOfFile:(NSString *)path error:(NSError **)error {
    NSData *data = [[NSData alloc] initWithContentsOfFile:path
                                                  options:NSDataReadingMappedIfSafe
                                                    error:error];
    if ([data length] == 0) {
        return nil;
    }
    return [self initWithData:data error:error];
}

/**
 *  Converts the internal bitmap to an NSImage.
 */
-(NSImage *)image {
    if (_bitmap == nil) {
        return nil;
    }
    return [[NSImage alloc] initWithCGImage:[_bitmap CGImage] size:[_bitmap size]];
}

/**
 *  Exports the bitmap to disk.
 */
-(BOOL)exportFile:(NSString *)path storageType:(NSBitmapImageFileType)type properties:(NSDictionary *)properties {
    NSBitmapImageRep *map = _bitmap;
    if (map == nil) {
        return NO;
    }
    
    NSData *img = [map representationUsingType:type properties:properties];
    return [img writeToFile:path atomically:YES];
}

/**
 *  Attempts to parse a BLP and convert it to an
 *  image object that we can easily work with.
 *
 *  @param  error   Pointer to receive errors, if any.
 *
 *  @returns        Returns NO on error.
 */
-(BOOL)parse:(NSError **)error {
    if ([_data length] == 0) {
        *error = [self constructError:@"Buffer contains zero bytes."
                          customErrno:0 posix:EPERM];
        return NO;
    }
    
    /*
     *  Verify magic number.
     */
    char magic[4];
    [_data getBytes:&magic length:4];
    
    if (strncmp(magic, "BLP1", 4) == 0) {
        return [self parseBLP1:error];
    } else if (strncmp(magic, "BLP2", 4) == 0) {
        return [self parseBLP2:error];
    } else {
        *error = [self constructError:@"Unknown magic number."
                          customErrno:2 posix:ENOTSUP];
        return NO;
    }
    
    return YES;
}

/**
 *  Parse a BLP1 file (Wc3).
 */
-(BOOL)parseBLP1:(NSError **)error {
    if ([_data length] < sizeof(HeaderBLP1)) {
        *error = [self constructError:@"Malformed header."
                          customErrno:3 posix:EPERM];
        return NO;
    }
    
    HeaderBLP1 header;
    [_data getBytes:&header length:sizeof(HeaderBLP1)];
    if (![self verifyHeaderBLP1:header]) {
        *error = [self constructError:@"Malformed header."
                          customErrno:3 posix:EPERM];
        return NO;
    }
    
    /*
     *  JPEG vs. Paletted
     */
    if (header.compression == 0) {
        return [self parseJPEG1:header mipmap:0 error:error];
    } else {
        return [self parsePalette1:header mipmap:0 error:error];
    }
    
    return YES;
}

/**
 *  Runs basic sanity checks on whether the header is
 *  properly constructed.
 */
-(BOOL)verifyHeaderBLP1:(HeaderBLP1)header {
    if (header.compression != 0 && header.compression != 1) {
        return NO;
    } else if (header.alphaBitDepth != 0 && header.alphaBitDepth != 8) {
        return NO;
    } else if (header.pictureType < 2 || header.pictureType > 5) {
        return NO;
    } else if (header.alphaBitDepth == 0 && header.pictureType != 5) {
        return NO;
    } else if (header.mipmapSize[0] == 0) {
        return NO;
    } else if (header.mipmapOffset[0] < sizeof(HeaderBLP1)) {
        return NO;
    }
    return YES;
}

/**
 *  Parse a BLP1 JPEG.
 */
-(BOOL)parseJPEG1:(HeaderBLP1)header mipmap:(NSInteger)index error:(NSError **)error {
    if ([_data length] < header.mipmapOffset[index] + header.mipmapSize[index]) {
        *error = [self constructError:@"Missing mipmap data."
                          customErrno:4 posix:EPERM];
        return NO;
    }
    if ([_data length] < header.mipmapOffset[index] + header.mipmapSize[index] ||
        header.mipmapSize[index] == 0) {
        *error = [self constructError:@"Missing mipmap data."
                          customErrno:4 posix:EPERM];
        return NO;
    }
    
    /*
     *  Retrieve JPEG header size (in bytes).
     */
    uint32_t offset = sizeof(HeaderBLP1);
    uint32_t jpegHeaderSize = 0;
    [_data getBytes:&jpegHeaderSize range:NSMakeRange(offset, 4)];
    
    /*
     *  Grab the JPEG global header.
     */
    NSData *jpegHeader = [_data subdataWithRange:NSMakeRange(offset + 4, jpegHeaderSize)];
    offset = header.mipmapOffset[index];
    
    /*
     *  Stitch the JPEG header with the JPEG data.
     */
    NSMutableData *jpeg = [[NSMutableData alloc] initWithData:jpegHeader];
    [jpeg appendData:[_data subdataWithRange:NSMakeRange(offset, header.mipmapSize[index])]];
    
    if (jpeg == nil || [jpeg length] < header.mipmapSize[index]) {
        *error = [self constructError:@"JPEG Parse Error."
                          customErrno:6 posix:EPERM];
        return NO;
    }
    
    /*
     *  Initialize JPEG data
     */
    unsigned long jpegSize = [jpeg length];
    unsigned char *jbuffer = (unsigned char *)[jpeg bytes];
    struct jpeg_decompress_struct cinfo;
    blp1_jpeg_error jerr;
    
    unsigned long bmpSize;
    unsigned char *bmpBuffer;
    int rowStride, width, height, components;
    
    cinfo.err = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit = blp1_error_exit;
    if (setjmp(jerr.setjmp_buffer)) {
        jpeg_destroy_decompress(&cinfo);
        *error = [self constructError:@"JPEG Parse Error."
                          customErrno:6 posix:EPERM];
        return NO;
    }
    
    jpeg_create_decompress(&cinfo);
    jpeg_mem_src(&cinfo, jbuffer, jpegSize);
    
    (void) jpeg_read_header(&cinfo, true);
    (void) jpeg_start_decompress(&cinfo);
    width  = cinfo.output_width;
    height = cinfo.output_height;
    components = cinfo.output_components;
    bmpSize = width * height * components;
    bmpBuffer = (unsigned char *) malloc(bmpSize);
    rowStride = width * components;
    
    /*
     *  Scan JPEG into a buffer
     */
    while (cinfo.output_scanline < cinfo.output_height) {
        unsigned char *bufferArray[1];
        bufferArray[0] = bmpBuffer + (cinfo.output_scanline) * rowStride;
        jpeg_read_scanlines(&cinfo, bufferArray, 1);
    }
    
    jpeg_finish_decompress(&cinfo);
    jpeg_destroy_decompress(&cinfo);
    BOOL hasAlpha = (header.alphaBitDepth == 8);
    
    /*
     *  Store in a bitmap.
     */
    _bitmap =
    [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                            pixelsWide:width
                                            pixelsHigh:height
                                         bitsPerSample:8
                                       samplesPerPixel:4
                                              hasAlpha:YES
                                              isPlanar:NO
                                        colorSpaceName:NSDeviceRGBColorSpace
                                          bitmapFormat:NSAlphaNonpremultipliedBitmapFormat
                                           bytesPerRow:0
                                          bitsPerPixel:32];
    
    offset = 0;
    for (int y = 0; y < height; y += 1) {
        for (int x = 0; x < width; x += 1) {
            uint8_t red = 0;
            memcpy(&red, (bmpBuffer + offset + 2), sizeof(uint8_t));
            
            uint8_t green = 0;
            memcpy(&green, (bmpBuffer + offset + 1), sizeof(uint8_t));
            
            uint8_t blue = 0;
            memcpy(&blue, (bmpBuffer + offset + 0), sizeof(uint8_t));
            
            uint8_t alpha = 0;
            memcpy(&alpha, (bmpBuffer + offset + 3), sizeof(uint8_t));
            if (!hasAlpha) {
                alpha = 255;
            }
            
            [_bitmap setColor:[NSColor colorWithCalibratedRed:red/255.0 green:green/255.0 blue:blue/255.0 alpha:alpha/255.0] atX:x y:y];
            offset += 4;
        }
    }
    free(bmpBuffer);
    return YES;
}

/**
 *  Parse a palette-based BLP1.
 */
-(BOOL)parsePalette1:(HeaderBLP1)header mipmap:(NSInteger)index error:(NSError **)error {
    if ([_data length] < sizeof(HeaderBLP1) + 256) {
        *error = [self constructError:@"Missing palette."
                          customErrno:7 posix:EPERM];
        return NO;
    }
    if ([_data length] < header.mipmapOffset[index] + header.mipmapSize[index] ||
        header.mipmapSize[index] == 0) {
        *error = [self constructError:@"Missing mipmap data."
                          customErrno:4 posix:EPERM];
        return NO;
    }
    
    uint32_t colors[256];
    [_data getBytes:&colors range:NSMakeRange(sizeof(HeaderBLP1), sizeof(colors))];
    
    /*
     *  Get the width and height of the mipmap.
     */
    int width = header.width;
    int height = header.height;
    BOOL hasAlpha = (header.alphaBitDepth == 8);
    for (int i = 1; i < index; i += 1) {
        width = MAX(width/2, 1);
        height = MAX(height/2, 1);
    }
    
    _bitmap =
    [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil
                                            pixelsWide:width
                                            pixelsHigh:height
                                         bitsPerSample:8
                                       samplesPerPixel:4
                                              hasAlpha:YES
                                              isPlanar:NO
                                        colorSpaceName:NSDeviceRGBColorSpace
                                          bitmapFormat:NS32BitLittleEndianBitmapFormat | NSAlphaNonpremultipliedBitmapFormat
                                           bytesPerRow:0
                                          bitsPerPixel:32];
    
    /*
     *  Go through each index and lookup the corresponding color
     *  within the palette.
     */
    int offset = header.mipmapOffset[index];
    int dimensionSize = width * height;
    for (int y = 0; y < height; y += 1) {
        for (int x = 0; x < width; x += 1) {
            uint8_t paletteIndex = 0;
            [_data getBytes:&paletteIndex range:NSMakeRange(offset, 1)];
            
            uint32_t rawColor = colors[paletteIndex];
            uint32_t alpha = 255 - ((rawColor & 0xFF000000) >> 24);
            uint32_t red   = (rawColor & 0x00FF0000) >> 16;
            uint32_t green = (rawColor & 0x0000FF00) >> 8;
            uint32_t blue  = (rawColor & 0x000000FF);
            
            if (!hasAlpha) {
                alpha = 255;
            }
            
            if (header.pictureType != 5 && hasAlpha) {
                [_data getBytes:&alpha range:NSMakeRange(offset + dimensionSize, 1)];
            }
            
            NSColor *color = [NSColor colorWithCalibratedRed:red / 255.0
                                                       green:green / 255.0
                                                        blue:blue / 255.0
                                                       alpha:alpha / 255.0];
            [_bitmap setColor:color atX:x y:y];
            offset += 1;
        }
    }
    
    return YES;
}

/**
 *  Parse a BLP2 file (WoW).
 */
-(BOOL)parseBLP2:(NSError **)error {
    if ([_data length] < sizeof(HeaderBLP2)) {
        *error = [self constructError:@"Malformed header."
                          customErrno:3 posix:EPERM];
        return NO;
    }
    
    HeaderBLP2 header;
    [_data getBytes:&header length:sizeof(HeaderBLP2)];
    if (![self verifyHeaderBLP2:header]) {
        *error = [self constructError:@"Malformed header."
                          customErrno:3 posix:EPERM];
        return NO;
    }
    
    if (header.compression == 1) {
        return [self parsePalette2:header mipmap:0 error:error];
    } else if (header.compression == 2) {
        return [self parseDXTC2:header mipmap:0 error:error];
    } else {
        return [self parseUncompressed2:header mipmap:0 error:error];
    }
    
    return NO;
}

/**
 *  Runs basic sanity checks on whether the header is
 *  properly constructed.
 */
-(BOOL)verifyHeaderBLP2:(HeaderBLP2)header {
    if (header.type != 0 && header.type != 1) {
        return NO;
    } else if (header.compression < 1 || header.compression > 3) {
        return NO;
    } else if (header.mipmapSize[0] == 0) {
        return NO;
    } else if (header.mipmapOffset[0] < sizeof(HeaderBLP2)) {
        return NO;
    }
    return YES;
}

/**
 *  Parse a paletted BLP2.
 */
-(BOOL)parsePalette2:(HeaderBLP2)header mipmap:(NSInteger)index error:(NSError **)error {
    if ([_data length] < header.mipmapOffset[index] + header.mipmapSize[index] ||
        header.mipmapSize[index] == 0) {
        *error = [self constructError:@"Missing mipmap data."
                          customErrno:4 posix:EPERM];
        return NO;
    }
    
    /*
     *  Get the width and height of the mipmap.
     */
    int width = header.width;
    int height = header.height;
    BOOL hasAlpha = (header.alphaBitDepth > 0);
    for (int i = 1; i < index; i += 1) {
        width = MAX(width/2, 1);
        height = MAX(height/2, 1);
    }
    
    _bitmap =
    [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil
                                            pixelsWide:width
                                            pixelsHigh:height
                                         bitsPerSample:8
                                       samplesPerPixel:4
                                              hasAlpha:YES
                                              isPlanar:NO
                                        colorSpaceName:NSDeviceRGBColorSpace
                                          bitmapFormat:NS32BitLittleEndianBitmapFormat | NSAlphaNonpremultipliedBitmapFormat
                                           bytesPerRow:0
                                          bitsPerPixel:32];
    
    /*
     *  Go through each index and lookup the corresponding color
     *  within the palette.
     */
    int offset = header.mipmapOffset[index];
    int dimensionSize = width * height;
    
    int alphaOffset = offset + dimensionSize;
    int shift = 0;
    for (int y = 0; y < height; y += 1) {
        for (int x = 0; x < width; x += 1) {
            uint8_t paletteIndex = 0;
            [_data getBytes:&paletteIndex range:NSMakeRange(offset, 1)];
            
            uint32_t rawColor = header.palette[paletteIndex];
            uint32_t alpha = 255 - ((rawColor & 0xFF000000) >> 24);
            uint32_t red   = (rawColor & 0x00FF0000) >> 16;
            uint32_t green = (rawColor & 0x0000FF00) >> 8;
            uint32_t blue  = (rawColor & 0x000000FF);
            
            if (!hasAlpha) {
                alpha = 255;
            }
            
            if (hasAlpha) {
                /*
                 *  Jump forward to alpha channel to extract alpha.
                 */
                uint8_t alphaByte = 0;
                [_data getBytes:&alphaByte range:NSMakeRange(alphaOffset, 1)];
                
                /*
                 *  Mask either 1-bit, 4-bits, or 8-bits.
                 */
                if (header.alphaBitDepth == 8) {
                    alphaOffset += 1;
                    alpha = alphaByte;
                } else if (header.alphaBitDepth == 1) {
                    uint8_t value = (alphaByte >> shift) & 0x1;
                    shift += 1;
                    if (shift == 8) {
                        alphaOffset += 1;
                        shift = 0;
                    }
                    alpha = value * 255;
                } else if (header.alphaBitDepth == 4) {
                    uint8_t value = (alphaByte >> shift) & 0xF;
                    shift += 4;
                    if (shift == 8) {
                        alphaOffset += 1;
                        shift = 0;
                    }
                    alpha = (int) (255 * ((float) value / 0xF));
                }
            }
            
            NSColor *color = [NSColor colorWithCalibratedRed:red / 255.0
                                                       green:green / 255.0
                                                        blue:blue / 255.0
                                                       alpha:alpha / 255.0];
            
            [_bitmap setColor:color atX:x y:y];
            offset += 1;
        }
    }
    
    return YES;
}

/**
 *  Parse a DXTC-based BLP2.
 */
-(BOOL)parseDXTC2:(HeaderBLP2)header mipmap:(NSInteger)index error:(NSError **)error {
    if ([_data length] < header.mipmapOffset[index] + header.mipmapSize[index] ||
        header.mipmapSize[index] == 0) {
        *error = [self constructError:@"Missing mipmap data."
                          customErrno:4 posix:EPERM];
        return NO;
    }
    
    unsigned long len = [_data length] - sizeof(HeaderBLP2);
    NSData *subdata = [_data subdataWithRange:NSMakeRange(sizeof(HeaderBLP2), len)];
    if (header.alphaType == 0) {
        if (header.alphaBitDepth == 0) {
            _bitmap = [DXTC decompress:subdata width:header.width height:header.height
                                format:DXTC_1];
        } else {
            _bitmap = [DXTC decompress:subdata width:header.width height:header.height
                                format:DXTC_1A];
        }
    } else if (header.alphaType == 1) {
        _bitmap = [DXTC decompress:subdata width:header.width height:header.height
                            format:DXTC_3];
    } else if (header.alphaType == 7) {
        _bitmap =[DXTC decompress:subdata width:header.width height:header.height
                           format:DXTC_5];
    } else {
        _bitmap = nil;
        return NO;
    }
    
    return YES;
}

/**
 *  Parse an uncompressed BLP2.
 */
-(BOOL)parseUncompressed2:(HeaderBLP2)header mipmap:(NSInteger)index error:(NSError **)error {
    if ([_data length] < header.mipmapOffset[index] + header.mipmapSize[index] ||
        header.mipmapSize[index] == 0) {
        *error = [self constructError:@"Missing mipmap data."
                          customErrno:4 posix:EPERM];
        return NO;
    }
    
    /*
     *  Get the width and height of the mipmap.
     */
    int width = header.width;
    int height = header.height;
    for (int i = 1; i < index; i += 1) {
        width = MAX(width/2, 1);
        height = MAX(height/2, 1);
    }
    
    _bitmap =
    [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil
                                            pixelsWide:width
                                            pixelsHigh:height
                                         bitsPerSample:8
                                       samplesPerPixel:4
                                              hasAlpha:YES
                                              isPlanar:NO
                                        colorSpaceName:NSDeviceRGBColorSpace
                                          bitmapFormat:NS32BitLittleEndianBitmapFormat | NSAlphaNonpremultipliedBitmapFormat
                                           bytesPerRow:0
                                          bitsPerPixel:32];
    
    /*
     *  Go through each color and extract their components.
     */
    int offset = header.mipmapOffset[index];
    for (int y = 0; y < height; y += 1) {
        for (int x = 0; x < width; x += 1) {
            uint32_t rawColor = 0;
            [_data getBytes:&rawColor range:NSMakeRange(offset, 4)];
            
            uint32_t alpha = ((rawColor & 0xFF000000) >> 24);
            uint32_t red   = (rawColor & 0x00FF0000) >> 16;
            uint32_t green = (rawColor & 0x0000FF00) >> 8;
            uint32_t blue  = (rawColor & 0x000000FF);
            
            NSColor *color = [NSColor colorWithCalibratedRed:red / 255.0
                                                       green:green / 255.0
                                                        blue:blue / 255.0
                                                       alpha:alpha / 255.0];
            
            [_bitmap setColor:color atX:x y:y];
            offset += 4;
        }
    }
    
    return YES;
}

/**
 *  Constructs an error with the given description
 *  with an underlying POSIX error.
 */
-(NSError *)constructError:(NSString *)desc customErrno:(NSInteger)err posix:(NSInteger)num {
    NSError *underlyingError = [NSError errorWithDomain:NSPOSIXErrorDomain code:num userInfo:nil];
    NSDictionary *errorDict = @{ NSLocalizedDescriptionKey : desc,
                                 NSUnderlyingErrorKey : underlyingError };
    return [[NSError alloc] initWithDomain:@"BLP" code:err userInfo:errorDict];
}

@end
