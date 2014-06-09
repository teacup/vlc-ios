/*****************************************************************************
 * VLCHTTPConnection.m
 * VLC for iOS
 *****************************************************************************
 * Copyright (c) 2013 VideoLAN. All rights reserved.
 * $Id$
 *
 * Authors: Felix Paul Kühne <fkuehne # videolan.org>
 *          Jean-Baptiste Kempf <jb # videolan.org>
 *
 * Refer to the COPYING file of the official project for license.
 *****************************************************************************/

#import "VLCAppDelegate.h"
#import "VLCHTTPConnection.h"
#import "HTTPConnection.h"
#import "MultipartFormDataParser.h"
#import "HTTPMessage.h"
#import "HTTPDataResponse.h"
#import "HTTPFileResponse.h"
#import "MultipartMessageHeaderField.h"
#import "VLCHTTPUploaderController.h"
#import "HTTPDynamicFileResponse.h"
#import "VLCThumbnailsCache.h"

@interface VLCHTTPConnection()
{
    MultipartFormDataParser *_parser;
    NSFileHandle *_storeFile;
    NSString *_filepath;
    UInt64 _contentLength;
    UInt64 _receivedContent;
}
@end

@implementation VLCHTTPConnection

- (BOOL)supportsMethod:(NSString *)method atPath:(NSString *)path
{
    // Add support for POST
    if ([method isEqualToString:@"POST"]) {
        if ([path isEqualToString:@"/upload.json"])
            return YES;
    }

    return [super supportsMethod:method atPath:path];
}

- (BOOL)expectsRequestBodyFromMethod:(NSString *)method atPath:(NSString *)path
{
    // Inform HTTP server that we expect a body to accompany a POST request
    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/upload.json"]) {
        // here we need to make sure, boundary is set in header
        NSString* contentType = [request headerField:@"Content-Type"];
        NSUInteger paramsSeparator = [contentType rangeOfString:@";"].location;
        if (NSNotFound == paramsSeparator)
            return NO;

        if (paramsSeparator >= contentType.length - 1)
            return NO;

        NSString* type = [contentType substringToIndex:paramsSeparator];
        if (![type isEqualToString:@"multipart/form-data"]) {
            // we expect multipart/form-data content type
            return NO;
        }

        // enumerate all params in content-type, and find boundary there
        NSArray* params = [[contentType substringFromIndex:paramsSeparator + 1] componentsSeparatedByString:@";"];
        for (NSString* param in params) {
            paramsSeparator = [param rangeOfString:@"="].location;
            if ((NSNotFound == paramsSeparator) || paramsSeparator >= param.length - 1)
                continue;

            NSString* paramName = [param substringWithRange:NSMakeRange(1, paramsSeparator-1)];
            NSString* paramValue = [param substringFromIndex:paramsSeparator+1];

            if ([paramName isEqualToString: @"boundary"])
                // let's separate the boundary from content-type, to make it more handy to handle
                [request setHeaderField:@"boundary" value:paramValue];
        }
        // check if boundary specified
        if (nil == [request headerField:@"boundary"])
            return NO;

        return YES;
    }
    return [super expectsRequestBodyFromMethod:method atPath:path];
}

- (NSObject<HTTPResponse> *)httpResponseForMethod:(NSString *)method URI:(NSString *)path
{
    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/upload.json"]) {
        return [[HTTPDataResponse alloc] initWithData:[@"\"OK\"" dataUsingEncoding:NSUTF8StringEncoding]];
    }
    if ([path hasPrefix:@"/download/"]) {
        NSString *filePath = [[path stringByReplacingOccurrencesOfString:@"/download/" withString:@""]stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        return [[HTTPFileResponse alloc] initWithFilePath:filePath forConnection:self];
    }
    if ([path hasPrefix:@"/thumbnail"]) {
        NSString *filePath = [[path stringByReplacingOccurrencesOfString:@"/thumbnail/" withString:@""]stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        filePath = [filePath stringByReplacingOccurrencesOfString:@".png" withString:@""];

        NSManagedObjectContext *moc = [[MLMediaLibrary sharedMediaLibrary] managedObjectContext];
        NSPersistentStoreCoordinator *psc = [moc persistentStoreCoordinator];
        NSManagedObject *mo = [moc existingObjectWithID:[psc managedObjectIDForURIRepresentation:[NSURL URLWithString:filePath]] error:nil];

        NSData *theData;
        if ([mo isKindOfClass:[MLFile class]])
            theData = UIImagePNGRepresentation([VLCThumbnailsCache thumbnailForMediaFile:(MLFile *)mo]);
        else if ([mo isKindOfClass:[MLShow class]])
            theData = UIImagePNGRepresentation([VLCThumbnailsCache thumbnailForShow:(MLShow *)mo]);
        else if ([mo isKindOfClass:[MLLabel class]])
            theData = UIImagePNGRepresentation([VLCThumbnailsCache thumbnailForLabel:(MLLabel *)mo]);
        else if ([mo isKindOfClass:[MLAlbum class]])
            theData = UIImagePNGRepresentation([VLCThumbnailsCache thumbnailForMediaFile:[[(MLAlbum *)mo tracks].anyObject files].anyObject]);

        if (theData)
            return [[HTTPDataResponse alloc] initWithData:theData];
    }
    NSString *filePath = [self filePathForURI:path];
    NSString *documentRoot = [config documentRoot];
    NSString *relativePath = [filePath substringFromIndex:[documentRoot length]];

    if ([relativePath isEqualToString:@"/index.html"]) {
        NSArray *allFiles = [MLFile allFiles];
        NSString *fileList = @"";
        for (MLFile *file in allFiles) {
            NSString *adaptedFileURL = [file.url stringByReplacingOccurrencesOfString:@"file://"withString:@""];
            NSString *fileHTML = [NSString stringWithFormat:@"<li><a href=\"download/%@\" download>%@</a> — <a href=\"thumbnail/%@.png\">preview</a></li>", adaptedFileURL, file.title, file.objectID.URIRepresentation];
            fileList = [fileList stringByAppendingString:fileHTML];
        }
        NSArray *allAlbums = [MLAlbum allAlbums];
        for (MLAlbum *album in allAlbums) {
            NSString *fileHTML = [NSString stringWithFormat:@"<li>%@ — <a href=\"thumbnail/%@.png\">preview</a></li>", album.name, album.objectID.URIRepresentation];
            fileList = [fileList stringByAppendingString:fileHTML];
        }
        NSArray *allShows = [MLShow allShows];
        for (MLShow *show in allShows) {
            NSString *fileHTML = [NSString stringWithFormat:@"<li>%@ — <a href=\"thumbnail/%@.png\">preview</a></li>", show.name, show.objectID.URIRepresentation];
            fileList = [fileList stringByAppendingString:fileHTML];
        }
        NSArray *allLabels = [MLLabel allLabels];
        for (MLLabel *label in allLabels) {
            NSString *fileHTML = [NSString stringWithFormat:@"<li>%@ — <a href=\"thumbnail/%@.png\">preview</a></li>", label.name, label.objectID.URIRepresentation];
            fileList = [fileList stringByAppendingString:fileHTML];
        }

        NSDictionary *replacementDict = @{@"FILES" : fileList,
                                          @"WEBINTF_TITLE" : NSLocalizedString(@"WEBINTF_TITLE", nil),
                                          @"WEBINTF_DROPFILES" : NSLocalizedString(@"WEBINTF_DROPFILES", nil),
                                          @"WEBINTF_DROPFILES_LONG" : NSLocalizedString(@"WEBINTF_DROPFILES_LONG", nil),
                                          @"WEBINTF_DOWNLOADFILES" : NSLocalizedString(@"WEBINTF_DOWNLOADFILES", nil),
                                          @"WEBINTF_DOWNLOADFILES_LONG" : NSLocalizedString(@"WEBINTF_DOWNLOADFILES_LONG", nil)};

        return [[HTTPDynamicFileResponse alloc] initWithFilePath:[self filePathForURI:path]
                                                   forConnection:self
                                                       separator:@"%%"
                                           replacementDictionary:replacementDict];
    } else if ([relativePath isEqualToString:@"/style.css"]) {
        NSDictionary *replacementDict = @{@"WEBINTF_TITLE" : NSLocalizedString(@"WEBINTF_TITLE", nil)};
        return [[HTTPDynamicFileResponse alloc] initWithFilePath:[self filePathForURI:path]
                                                   forConnection:self
                                                       separator:@"%%"
                                           replacementDictionary:replacementDict];
    }

    return [super httpResponseForMethod:method URI:path];
}

- (void)prepareForBodyWithSize:(UInt64)contentLength
{
    // set up mime parser
    NSString* boundary = [request headerField:@"boundary"];
    _parser = [[MultipartFormDataParser alloc] initWithBoundary:boundary formEncoding:NSUTF8StringEncoding];
    _parser.delegate = self;

    APLog(@"expecting file of size %lli kB", contentLength / 1024);
    _contentLength = contentLength;
}

- (void)processBodyData:(NSData *)postDataChunk
{
    /* append data to the parser. It will invoke callbacks to let us handle
     * parsed data. */
    [_parser appendData:postDataChunk];

    _receivedContent += postDataChunk.length;

    APLog(@"received %lli kB (%lli %%)", _receivedContent / 1024, ((_receivedContent * 100) / _contentLength));
}

//-----------------------------------------------------------------
#pragma mark multipart form data parser delegate


- (void)processStartOfPartWithHeader:(MultipartMessageHeader*) header
{
    /* in this sample, we are not interested in parts, other then file parts.
     * check content disposition to find out filename */

    MultipartMessageHeaderField* disposition = (header.fields)[@"Content-Disposition"];
    NSString* filename = [(disposition.params)[@"filename"] lastPathComponent];

    if ((nil == filename) || [filename isEqualToString: @""]) {
        // it's either not a file part, or
        // an empty form sent. we won't handle it.
        return;
    }

    // create the path where to store the media temporarily
    NSArray *searchPaths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString* uploadDirPath = [searchPaths[0] stringByAppendingPathComponent:@"Upload"];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    BOOL isDir = YES;
    if (![fileManager fileExistsAtPath:uploadDirPath isDirectory:&isDir ]) {
        [fileManager createDirectoryAtPath:uploadDirPath withIntermediateDirectories:YES attributes:nil error:nil];
    }

    _filepath = [uploadDirPath stringByAppendingPathComponent: filename];

    APLog(@"Saving file to %@", _filepath);
    if (![fileManager createDirectoryAtPath:uploadDirPath withIntermediateDirectories:true attributes:nil error:nil])
        APLog(@"Could not create directory at path: %@", _filepath);

    if (![fileManager createFileAtPath:_filepath contents:nil attributes:nil])
        APLog(@"Could not create file at path: %@", _filepath);

    _storeFile = [NSFileHandle fileHandleForWritingAtPath:_filepath];
    [(VLCAppDelegate*)[UIApplication sharedApplication].delegate networkActivityStarted];
    [(VLCAppDelegate*)[UIApplication sharedApplication].delegate disableIdleTimer];
}

- (void)processContent:(NSData*)data WithHeader:(MultipartMessageHeader*) header
{
    // here we just write the output from parser to the file.
    if (_storeFile) {
        @try {
            [_storeFile writeData:data];
        }
        @catch (NSException *exception) {
            APLog(@"File to write further data because storage is full.");
            [_storeFile closeFile];
            _storeFile = nil;
            /* don't block */
            [self performSelector:@selector(stop) withObject:nil afterDelay:0.1];
        }
    }

}

- (void)processEndOfPartWithHeader:(MultipartMessageHeader*)header
{
    // as the file part is over, we close the file.
    APLog(@"closing file");
    [_storeFile closeFile];
    _storeFile = nil;
}

- (BOOL)shouldDie
{
    if (_filepath) {
        if (_filepath.length > 0)
            [[(VLCAppDelegate*)[UIApplication sharedApplication].delegate uploadController] moveFileFrom:_filepath];
    }
    return [super shouldDie];
}

@end
