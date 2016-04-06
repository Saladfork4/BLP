//
//  BLP.h
//  BLP
//
//  Created by Saladfork on 8/24/15.
//  Copyright (c) 2015 Saladfork. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <Quartz/Quartz.h>
#import "jpeglib.h"
#import "DXTC.h"

@interface BLP : NSObject

@property (strong) NSData  * _Nonnull data;
@property (strong) NSBitmapImageRep * _Nonnull bitmap;

/**
 *  Initializes the BLP with the contents of the file.
 *
 *  @param path     Path to the file.
 *  @param error    Pointer to receive errors, if any.
 *                  This field can be nil.
 *
 *  @returns        New instance. It will attempt to parse
 *                  the BLP and convert it to an image.
 *                  Upon error, it will return nil.
 */
-(nullable id)initWithContentsOfFile:(nonnull NSString *)path
                               error:( NSError * _Nullable * _Nullable)error;

/**
 *  Initializes the BLP using the data within an NSData object.
 *
 *  @param data     Data representation of the BLP file.
 *  @param error    Pointer to receive errors, if any.
 *                  This field can be nil.
 *
 *  @returns        New instance. It will attempt to parse
 *                  the BLP and convert it to an image.
 *                  Upon error, it will return nil.
 */
-(nullable id)initWithData:(nonnull NSData *)data
                     error:( NSError * _Nullable * _Nullable)error;

/**
 *  Converts the internal bitmap representation to an
 *  NSImage object.
 *
 *  @returns        NSImage if the BLP was successfully converted.
 */
-(nullable NSImage *)image;

/**
 *  Exports the internal bitmap representation to disk.
 *
 *  @param path         Path on disk.
 *  @param storageType  Recommended NSPNGFileType.
 *  @param properties   Some types (e.g. TIFF) have additional
 *                      properties related to compression.
 *
 *  @returns            YES on success.
 */
-(BOOL)exportFile:(nonnull NSString *)path storageType:(NSBitmapImageFileType)type
       properties:(nullable NSDictionary *)properties;

@end

/**
 *  BLP1 Header
 */
typedef struct _HeaderBLP1 {
    
    char     magic[4];          /*   Magic file identifier: BLP1   */
    uint32_t compression;       /*
                                 *   0: JPEG
                                 *   1: Paletted
                                 */
    
    uint32_t alphaBitDepth;     /*
                                 *   Alpha channel bit depth
                                 *   0: No alpha
                                 *   8: 8-bit alpha values
                                 */
    
    uint32_t width;
    uint32_t height;
    uint32_t pictureType;       /*
                                 *   2: Glues
                                 *   3: Uncompressed index list + alpha list
                                 *   4: Uncompressed index list + alpha list
                                 *   5: Uncompressed index list
                                 */
    
    uint32_t subType;           /*
                                 *   0: Shadows/WorldEditUI
                                 *      Width/height not necessarily power of 2
                                 *
                                 *   1: Everything else
                                 */
    
    uint32_t mipmapOffset[16];  /*   Mipmap offset list    */
    uint32_t mipmapSize[16];    /*   Mipmap size (bytes)   */
    
} HeaderBLP1;

/**
 *  BLP2 Header
 */
typedef struct _HeaderBLP2 {
    
    char     magic[4];          /*   Magic file identifier: BLP2   */
    uint32_t type;              /*
                                 *   0: JPEG (unused)
                                 *   1: Paletted | DXTC | Uncompressed
                                 */
    
    uint8_t  compression;       /*
                                 *   1: Paletted
                                 *   2: DXTC
                                 *   3: Uncompressed
                                 */
    
    uint8_t  alphaBitDepth;     /*   0 | 1 | 4 | 8   */
    uint8_t  alphaType;         /*   0 | 1 | 7 | 8   */
    uint8_t  hasMips;           /*   0 | 1           */
    
    uint32_t width;
    uint32_t height;
    uint32_t mipmapOffset[16];  /*   Mipmap offset list    */
    uint32_t mipmapSize[16];    /*   Mipmap size (bytes)   */
    uint32_t palette[256];      /*   Color Palette         */
    
} HeaderBLP2;

/**
 *  JPEG Error Handling
 */
typedef struct _blp1_jpeg_error {
    struct jpeg_error_mgr pub;
    jmp_buf setjmp_buffer;
} blp1_jpeg_error, *blp1_jpeg_error_ptr;

METHODDEF(void)
blp1_error_exit (_Nonnull j_common_ptr cinfo)
{
    blp1_jpeg_error_ptr myerr = (blp1_jpeg_error_ptr) cinfo->err;
    (*cinfo->err->output_message) (cinfo);
    longjmp(myerr->setjmp_buffer, 1);
}
