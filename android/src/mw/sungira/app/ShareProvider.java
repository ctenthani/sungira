package mw.sungira.app;
import android.content.ContentProvider;import android.content.ContentValues;import android.database.Cursor;import android.database.MatrixCursor;import android.net.Uri;import android.os.ParcelFileDescriptor;import android.provider.OpenableColumns;import java.io.*;
public class ShareProvider extends ContentProvider {
 public boolean onCreate(){return true;}
 private File resolve(Uri uri) throws FileNotFoundException {String name=uri.getLastPathSegment();if(name==null||!name.matches("[A-Za-z0-9._-]{1,120}"))throw new FileNotFoundException();File folder=new File(getContext().getCacheDir(),"exports");File f=new File(folder,name);try{if(!f.getCanonicalPath().startsWith(folder.getCanonicalPath()+File.separator))throw new FileNotFoundException();}catch(IOException e){throw new FileNotFoundException();}return f;}
 public ParcelFileDescriptor openFile(Uri uri,String mode)throws FileNotFoundException {if(!"r".equals(mode))throw new FileNotFoundException("Read only");return ParcelFileDescriptor.open(resolve(uri),ParcelFileDescriptor.MODE_READ_ONLY);}
 public String getType(Uri uri){String n=uri.getLastPathSegment();if(n!=null&&n.endsWith(".png"))return "image/png";if(n!=null&&n.endsWith(".html"))return "text/html";if(n!=null&&n.endsWith(".csv"))return "text/csv";return "application/octet-stream";}
 public Cursor query(Uri uri,String[] projection,String selection,String[] args,String sort){try{File f=resolve(uri);MatrixCursor c=new MatrixCursor(new String[]{OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE});c.addRow(new Object[]{f.getName(),f.length()});return c;}catch(Exception e){return null;}}
 public Uri insert(Uri u,ContentValues v){throw new UnsupportedOperationException();}public int update(Uri u,ContentValues v,String s,String[] a){throw new UnsupportedOperationException();}public int delete(Uri u,String s,String[] a){throw new UnsupportedOperationException();}
}
