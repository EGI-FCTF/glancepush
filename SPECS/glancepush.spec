Summary: Automate images testing and publishing into Openstack Glance images catalog
Name: glancepush
Version: 0.1
Release: 1
Group: Applications/System
Packager: Mattieu Puel
License: GPL2
BuildRoot: %{_builddir}/osimgpublish
BuildArch: noarch
Requires: python-novaclient, python-glanceclient, python-confparser, python-dateutil, pytz



%description
Automate images testing and publishing into Openstack Glance images catalog.




%install
rsync --exclude .svn -av %{_sourcedir}/ $RPM_BUILD_ROOT/



%post
# add the disabled service
chkconfig --add glancepush
chkconfig glancepush off


%postun
# remove the service
chkconfig --del glancepush
true



%clean 
[ "$RPM_BUILD_ROOT" != "/" ] && rm -rf $RPM_BUILD_ROOT




%files
%defattr(0755,root,root)
/usr/bin/gppublish
/usr/bin/gppolcheck
/usr/bin/gpupdate
/usr/bin/gpextractmeta
/usr/share/glancepush/common.sh
/usr/share/man/man1/gppublish.1.gz
/usr/share/man/man1/gppolcheck.1.gz
/usr/share/man/man1/gpupdate.1.gz
/usr/share/man/man1/gpextractmeta.1.gz
/usr/share/man/man5/glancepushrc.5.gz
/var/log/glancepush
/var/run/glancepush
/var/lib/glancepush/cron
/etc/glancepush/test
/etc/glancepush/meta
/etc/glancepush/transform
/etc/rc.d/init.d/glancepush
%defattr(0644,root,root)
/etc/glancepush/meta/example
/etc/glancepush/test/example
/etc/glancepush/test/lib
%config(noreplace)
/etc/glancepush/glancepushrc



%changelog
* Fri Feb 01 2013 Mattieu Puel 0.1-1
- first release
